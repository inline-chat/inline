import { AudioStream, Room, RoomEvent, TrackKind, TrackSource, dispose,
  type AudioFrame, type RemoteParticipant, type RemoteTrackPublication, type RemoteTrack } from "@livekit/rtc-node"
import { CaptureAuthority, type CaptureIdentity, type MicrophoneGrant } from "./authority.js"
import { SPEAKER_LIMIT, RunControlClient, type ClaimedRun, type ParticipantGrant } from "./api.js"
import { TranscriptionError } from "./protocol.js"
import { SileroModel } from "./silero.js"
import { TrackWorker, type SpeechConnection } from "./track-worker.js"
import type { ProviderOptions } from "./socket.js"
import { monotonicMilliseconds } from "./watchdog.js"

type OwnedMicrophone = {
  participant: RemoteParticipant; publication: RemoteTrackPublication; track: RemoteTrack;
  grant: MicrophoneGrant; worker: TrackWorker; reader: ReadableStreamDefaultReader<AudioFrame>;
  reading: Promise<void>; retirement?: Promise<void>;
}
export type RoomWorkerOptions = Readonly<{
  run: ClaimedRun; identity: CaptureIdentity; requestedAtMs: number; leaseMs: number; expiresAtMs: number;
  apiBaseUrl: string; apiKey: string; apiTimeoutMs?: number;
  onFailure: (error: TranscriptionError) => void;
  // Trusted local qualification injection; the daemon never accepts endpoints over IPC.
  connectProvider?: (options: ProviderOptions) => Promise<SpeechConnection>;
}>

// One native process owns one room. An uncancellable native connect/disconnect is
// contained by the independent watchdog; it is never claimed stopped by a raced timeout.
export class RoomWorker {
  private readonly room = new Room()
  private readonly authority: CaptureAuthority
  private readonly api: RunControlClient
  private manifest = new Map<string, ParticipantGrant>()
  private readonly microphones = new Map<string, OwnedMicrophone>()
  private model: SileroModel | undefined
  private accepting = true
  private stopped = false
  private connected: Promise<void> | undefined
  private stopPromise: Promise<void> | undefined

  constructor(private readonly options: RoomWorkerOptions) {
    this.authority = new CaptureAuthority({
      identity: options.identity, requestedAtMs: options.requestedAtMs, leaseMs: options.leaseMs,
      expiresAtMs: options.expiresAtMs, microphones: [], now: monotonicMilliseconds,
    })
    this.api = new RunControlClient(options.apiBaseUrl, options.run.runToken, options.apiTimeoutMs)
    this.replaceManifest(options.run.participants)
    // These handlers must exist before connect can deliver its buffered room events.
    this.room.on(RoomEvent.ParticipantConnected, () => this.reconcileSafely())
    this.room.on(RoomEvent.ParticipantDisconnected, () => this.reconcileSafely())
    this.room.on(RoomEvent.TrackPublished, () => this.reconcileSafely())
    this.room.on(RoomEvent.TrackUnpublished, () => this.reconcileSafely())
    this.room.on(RoomEvent.TrackMuted, () => this.reconcileSafely())
    this.room.on(RoomEvent.TrackUnmuted, () => this.reconcileSafely())
    this.room.on(RoomEvent.TrackSubscribed, (track, publication, participant) => {
      if (!this.accepting) { publication.setSubscribed(false); return }
      try { this.reconcile(); this.attach(track, publication, participant) } catch (error) { this.fail(error) }
    })
    this.room.on(RoomEvent.TrackUnsubscribed, (_track, publication) => {
      const owned = publication.sid ? this.microphones.get(publication.sid) : undefined
      if (owned) this.retire(owned)
    })
    this.room.on(RoomEvent.TrackSubscriptionFailed, () => this.fail(new TranscriptionError("audio")))
    // v1 ends capture on a media gap. Voice remains independently owned by clients.
    this.room.on(RoomEvent.Reconnecting, () => this.fail(new TranscriptionError("audio")))
    this.room.on(RoomEvent.Disconnected, () => { if (this.accepting) this.fail(new TranscriptionError("audio")) })
  }

  async start(): Promise<void> {
    this.authority.assertCurrent(this.options.identity)
    const model = await SileroModel.load()
    if (!this.accepting) { await model.close(); throw new TranscriptionError("stopped") }
    this.model = model
    this.authority.assertCurrent(this.options.identity)
    this.connected = this.room.connect(this.options.run.livekit.serverUrl, this.options.run.livekit.token, {
      autoSubscribe: false, dynacast: false, dataStream: { maxPayloadByteLength: 1024 },
    })
    try { await this.connected } catch { throw new TranscriptionError("audio") }
    if (!this.accepting) throw new TranscriptionError("stopped")
    this.authority.assertCurrent(this.options.identity)
    // Events and this sweep cover both already-published and subsequently-published microphones.
    this.reconcile()
  }

  renew(identity: CaptureIdentity, requestedAtMs: number, leaseMs: number, manifest: readonly ParticipantGrant[]): void {
    if (!this.accepting) throw new TranscriptionError("stopped")
    this.authority.renew(identity, requestedAtMs, leaseMs)
    this.replaceManifest(manifest)
    this.reconcile()
  }
  private replaceManifest(participants: readonly ParticipantGrant[]): void {
    this.manifest = new Map(participants.map((participant) => [participant.identity, participant]))
  }
  private eligible(publication: RemoteTrackPublication, participant: RemoteParticipant): MicrophoneGrant | undefined {
    this.authority.assertCurrent(this.options.identity)
    const membership = this.manifest.get(participant.identity)
    const sid = publication.sid
    if (!membership || !sid || this.room.remoteParticipants.get(participant.identity) !== participant
      || participant.trackPublications.get(sid) !== publication || publication.kind !== TrackKind.KIND_AUDIO
      || publication.source !== TrackSource.SOURCE_MICROPHONE || publication.muted !== false) return undefined
    return { identity: membership.identity, trackSid: sid, speakerUserId: membership.userId, membershipId: membership.membershipId }
  }
  private reconcileSafely(): void {
    if (!this.accepting) return
    try { this.reconcile() } catch (error) { this.fail(error) }
  }
  private reconcile(): void {
    if (!this.accepting) return
    const publications: { participant: RemoteParticipant; publication: RemoteTrackPublication; grant: MicrophoneGrant }[] = []
    for (const participant of this.room.remoteParticipants.values()) {
      for (const publication of participant.trackPublications.values()) {
        const grant = this.eligible(publication, participant)
        if (grant) publications.push({ participant, publication, grant })
        else if (publication.subscribed) publication.setSubscribed(false)
      }
    }
    if (publications.length > SPEAKER_LIMIT) throw new TranscriptionError("overflow")
    this.authority.replaceMicrophones(this.options.identity, publications.map((entry) => entry.grant))
    for (const owned of this.microphones.values()) {
      if (!this.isCurrent(owned)) this.retire(owned)
    }
    for (const entry of publications) {
      if (!entry.publication.subscribed) entry.publication.setSubscribed(true)
      if (entry.publication.track) this.attach(entry.publication.track, entry.publication, entry.participant)
    }
  }
  private isCurrent(owned: OwnedMicrophone): boolean {
    const grant = this.eligible(owned.publication, owned.participant)
    return !owned.retirement && !!grant && grant.membershipId === owned.grant.membershipId
      && grant.speakerUserId === owned.grant.speakerUserId && owned.publication.track === owned.track
  }
  private attach(track: RemoteTrack, publication: RemoteTrackPublication, participant: RemoteParticipant): void {
    if (!this.accepting || !this.model) return
    const grant = this.eligible(publication, participant)
    if (!grant || publication.track !== track) { publication.setSubscribed(false); return }
    const existing = this.microphones.get(grant.trackSid)
    if (existing) {
      if (existing.track !== track || existing.publication !== publication) throw new TranscriptionError("protocol")
      return
    }
    // Retiring tracks count until their provider work is drained, bounding track churn too.
    if (this.microphones.size >= SPEAKER_LIMIT) throw new TranscriptionError("overflow")
    const sampleRate = this.options.run.model === "meeting" ? 16_000 : 24_000
    const reader = new AudioStream(track, { sampleRate, numChannels: 1, frameSizeMs: 20 }).getReader()
    let owned: OwnedMicrophone | undefined
    const worker = new TrackWorker({
      model: this.options.run.model, apiKey: this.options.apiKey,
      participantIdentity: grant.identity, trackSid: grant.trackSid, api: this.api,
      detector: this.model.detector(sampleRate),
      ...(this.options.connectProvider ? { connect: this.options.connectProvider } : {}),
      assertRunAuthority: () => this.authority.assertCurrent(this.options.identity),
      assertMicrophone: () => {
        const current = this.eligible(publication, participant)
        if (!this.accepting || owned?.retirement || !current || publication.track !== track
          || current.membershipId !== grant.membershipId || current.speakerUserId !== grant.speakerUserId) {
          throw new TranscriptionError("stopped")
        }
        const verified = this.authority.microphone(this.options.identity, {
          identity: participant.identity, trackSid: grant.trackSid, kind: "audio", source: "microphone",
        })
        if (!verified || verified.membershipId !== grant.membershipId) throw new TranscriptionError("stopped")
      },
      onFailure: (error) => this.fail(error),
    })
    owned = { participant, publication, track, grant, worker, reader, reading: Promise.resolve() }
    this.microphones.set(grant.trackSid, owned)
    owned.reading = this.read(owned)
  }
  private async read(owned: OwnedMicrophone): Promise<void> {
    try {
      while (this.accepting && !owned.retirement) {
        const result = await owned.reader.read()
        if (result.done) { if (this.accepting && !owned.retirement) this.retire(owned); return }
        if (!this.accepting || owned.retirement || !this.isCurrent(owned)) return
        if (result.value.sampleRate !== owned.worker.sampleRate || result.value.channels !== 1
          || result.value.data.length !== result.value.samplesPerChannel) throw new TranscriptionError("audio")
        // No await between this authority check and the owned bounded queue write.
        owned.worker.push(result.value.data)
      }
    } catch (error) { if (this.accepting && !owned.retirement) this.fail(error) }
    finally { try { owned.reader.releaseLock() } catch { /* Pending cancellation owns the lock until it completes. */ } }
  }
  private retire(owned: OwnedMicrophone): void {
    if (owned.retirement) return
    this.authority.revoke(owned.grant.trackSid)
    owned.publication.setSubscribed(false)
    const flushing = owned.worker.stop(true)
    const cancellation = owned.reader.cancel().catch(() => undefined)
    owned.retirement = Promise.all([flushing, cancellation, owned.reading]).then(() => {
      if (this.microphones.get(owned.grant.trackSid) === owned) this.microphones.delete(owned.grant.trackSid)
    }).catch((error: unknown) => this.fail(error))
  }
  private fail(error: unknown): void {
    if (!this.accepting) return
    // Close every queue immediately; teardown continues only in the native child.
    void this.stop(false).catch(() => undefined)
    this.options.onFailure(error instanceof TranscriptionError ? error : new TranscriptionError("audio"))
  }
  stop(graceful: boolean): Promise<void> {
    this.accepting = false
    if (!graceful) {
      this.authority.stop()
      for (const owned of this.microphones.values()) void owned.worker.stop(false)
    }
    if (this.stopPromise) return this.stopPromise
    const closing: Promise<unknown>[] = []
    for (const owned of this.microphones.values()) {
      owned.publication.setSubscribed(false)
      closing.push(owned.worker.stop(graceful), owned.reader.cancel().catch(() => undefined), owned.reading)
    }
    this.stopPromise = this.finishStop(closing)
    return this.stopPromise
  }
  private async finishStop(closing: readonly Promise<unknown>[]): Promise<void> {
    // Waiting for the real native operation is intentional. Watchdog escalation
    // kills this process if native teardown or a pending connect never settles.
    await Promise.allSettled(closing)
    if (this.connected) { try { await this.connected } catch { /* Failed connect has no connected transport. */ } }
    await this.room.disconnect()
    this.room.removeAllListeners()
    await this.model?.close()
    this.authority.stop()
    this.microphones.clear()
    dispose()
    this.stopped = true
  }
  get isStopped(): boolean { return this.stopped }
}
