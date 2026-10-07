import { TranscriptionError } from "./protocol.js"

export type CaptureIdentity = Readonly<{ runId: string; claimEpoch: number; generation: number }>
export type MicrophoneGrant = Readonly<{ identity: string; trackSid: string; speakerUserId: string; membershipId: string }>
export type Publication = Readonly<{ identity: string; trackSid: string; kind: "audio" | "video"; source: "microphone" | "screen" | "other" }>

// Construct only from verified API authority. Mutable room metadata is never a grant.
export class CaptureAuthority {
  private stopped = false
  private deadlineMs: number
  private lastRenewRequestMs: number
  private readonly tracks = new Map<string, MicrophoneGrant>()
  readonly identity: CaptureIdentity

  constructor(options: {
    identity: CaptureIdentity; requestedAtMs: number; leaseMs: number; expiresAtMs: number;
    microphones: readonly MicrophoneGrant[]; now?: () => number;
  }) {
    this.identity = Object.freeze({ ...options.identity })
    this.now = options.now ?? (() => performance.now())
    this.expiresAtMs = options.expiresAtMs
    this.lastRenewRequestMs = options.requestedAtMs
    this.deadlineMs = this.deadline(options.requestedAtMs, options.leaseMs)
    if (!options.identity.runId || !Number.isSafeInteger(options.identity.claimEpoch) || options.identity.claimEpoch <= 0
      || !Number.isSafeInteger(options.identity.generation) || options.identity.generation < 0) throw new TranscriptionError("protocol")
    if (options.microphones.length > 8) throw new TranscriptionError("overflow")
    for (const grant of options.microphones) {
      if (!grant.identity || !grant.trackSid || !grant.speakerUserId || !grant.membershipId || this.tracks.has(grant.trackSid)) {
        throw new TranscriptionError("protocol")
      }
      this.tracks.set(grant.trackSid, Object.freeze({ ...grant }))
    }
    this.assertCurrent(this.identity)
  }

  private readonly now: () => number
  private readonly expiresAtMs: number

  private deadline(requestedAtMs: number, leaseMs: number): number {
    if (!Number.isFinite(requestedAtMs) || !Number.isFinite(this.expiresAtMs)
      || !Number.isFinite(leaseMs) || leaseMs <= 0 || leaseMs > 30_000 || requestedAtMs > this.now()) {
      throw new TranscriptionError("protocol")
    }
    return Math.min(requestedAtMs + leaseMs, this.expiresAtMs)
  }

  assertCurrent(identity: CaptureIdentity): void {
    if (this.stopped) throw new TranscriptionError("stopped")
    if (this.now() >= this.deadlineMs) {
      this.stop()
      throw new TranscriptionError("expired")
    }
    if (identity.runId !== this.identity.runId || identity.claimEpoch !== this.identity.claimEpoch
      || identity.generation !== this.identity.generation) throw new TranscriptionError("protocol")
  }

  // A delayed response counts from request start and cannot resurrect expired authority.
  renew(identity: CaptureIdentity, requestedAtMs: number, leaseMs: number): void {
    this.assertCurrent(identity)
    const deadline = this.deadline(requestedAtMs, leaseMs)
    if (requestedAtMs <= this.lastRenewRequestMs) return
    if (deadline <= this.now()) {
      this.stop()
      throw new TranscriptionError("expired")
    }
    this.lastRenewRequestMs = requestedAtMs
    this.deadlineMs = deadline
  }

  microphone(identity: CaptureIdentity, publication: Publication): MicrophoneGrant | undefined {
    this.assertCurrent(identity)
    const grant = this.tracks.get(publication.trackSid)
    if (publication.kind !== "audio" || publication.source !== "microphone" || !grant
      || grant.identity !== publication.identity) return undefined
    return grant
  }

  revoke(trackSid: string): void { this.tracks.delete(trackSid) }
  // Atomically join the verified API membership manifest with current microphone publications.
  replaceMicrophones(identity: CaptureIdentity, grants: readonly MicrophoneGrant[]): void {
    this.assertCurrent(identity)
    if (grants.length > 8) throw new TranscriptionError("overflow")
    const next = new Map<string, MicrophoneGrant>()
    for (const grant of grants) {
      if (!grant.identity || !grant.trackSid || !grant.speakerUserId || !grant.membershipId || next.has(grant.trackSid)) {
        throw new TranscriptionError("protocol")
      }
      next.set(grant.trackSid, Object.freeze({ ...grant }))
    }
    this.tracks.clear()
    for (const [sid, grant] of next) this.tracks.set(sid, grant)
  }
  stop(): void { this.stopped = true; this.tracks.clear() }
}
