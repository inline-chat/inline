import { randomUUID } from "node:crypto"
import { BoundedPcmQueue } from "./pcm.js"
import { MAX_PENDING_TURNS, TranscriptionError, type FinalTurn, type Model } from "./protocol.js"
import { SpeechSegmenter } from "./segmenter.js"
import type { SpeechDetector } from "./silero.js"
import { ProviderConnection, type ProviderOptions } from "./socket.js"
import { monotonicMilliseconds } from "./watchdog.js"

export interface TurnApi {
  admit(participantIdentity: string, trackSid: string, sourceTurnKey: string): Promise<string>
  final(segmentId: string, text: string): Promise<void>
}
export interface SpeechConnection { appendAudio(samples: Int16Array): void; commitTurn(id: string): void; close(): void }
export type TrackWorkerOptions = Readonly<{
  model: Model; apiKey: string; participantIdentity: string; trackSid: string;
  api: TurnApi; detector: SpeechDetector;
  assertRunAuthority: () => void; assertMicrophone: () => void;
  onFailure: (error: TranscriptionError) => void;
  connect?: (options: ProviderOptions) => Promise<SpeechConnection>;
  now?: () => number;
}>
type PendingTurn = { timer: NodeJS.Timeout; posting: boolean }
const FINAL_TIMEOUT_MS = 5_000
const SOCKET_MAX_AGE_MS = 9 * 60 * 1000
const SOCKET_MAX_TURNS = 900

// Exactly one consumer owns each speaker's VAD, admission and provider commit order.
// Native RTC readers only push owned copies and never wait for inference or network I/O.
export class TrackWorker {
  readonly sampleRate: number
  private readonly queue: BoundedPcmQueue
  private readonly segmenter: SpeechSegmenter
  private readonly now: () => number
  private readonly consumer: Promise<void>
  private accepting = true
  private closed = false
  private graceful = false
  private connection: SpeechConnection | undefined
  private connectionStartedAt = 0
  private socketTurns = 0
  private rotationTimer: NodeJS.Timeout | undefined
  private current: { id: string; samples: number } | undefined
  private readonly pending = new Map<string, PendingTurn>()
  private readonly posting = new Set<Promise<void>>()
  private closePromise: Promise<void> | undefined
  private drainResolve: (() => void) | undefined
  private drainTimer: NodeJS.Timeout | undefined
  private processingTimer: NodeJS.Timeout | undefined

  constructor(private readonly options: TrackWorkerOptions) {
    this.sampleRate = options.model === "meeting" ? 16_000 : 24_000
    this.queue = new BoundedPcmQueue(this.sampleRate * 2)
    this.segmenter = new SpeechSegmenter(this.sampleRate)
    this.now = options.now ?? monotonicMilliseconds
    options.assertRunAuthority()
    options.assertMicrophone()
    this.consumer = this.consume().catch((error: unknown) => {
      if (this.accepting) this.fail(error)
    })
  }

  push(samples: Int16Array): void {
    if (!this.accepting || this.closed) throw new TranscriptionError("stopped")
    try {
      this.options.assertRunAuthority()
      this.options.assertMicrophone()
      if (samples.length > this.sampleRate / 10) throw new TranscriptionError("audio")
      this.queue.push(samples)
    } catch (error) { this.fail(error); throw this.safe(error) }
  }

  private async consume(): Promise<void> {
    while (this.accepting) {
      const frame = await this.queue.take()
      if (!frame || !this.accepting) return
      // Native inference may not support cancellation. Failure closes the queue;
      // room/process supervision contains a late or permanently blocked operation.
      this.processingTimer = setTimeout(() => this.fail(new TranscriptionError("audio")), 7_000)
      try {
      this.options.assertRunAuthority()
      this.options.assertMicrophone()
      const probability = await this.options.detector.probability(frame)
      if (!this.accepting) return
      this.options.assertRunAuthority()
      this.options.assertMicrophone()
      for (const action of this.segmenter.accept(frame, probability)) {
        if (!this.accepting) return
        if (action.kind === "start") await this.startTurn(action.frames)
        else if (action.kind === "audio") this.append(action.frame)
        else this.commit()
      }
      } finally { clearTimeout(this.processingTimer); this.processingTimer = undefined }
    }
  }

  private async startTurn(frames: readonly Int16Array[]): Promise<void> {
    if (this.current || this.pending.size >= MAX_PENDING_TURNS) throw new TranscriptionError("overflow")
    this.options.assertRunAuthority()
    this.options.assertMicrophone()
    const id = await this.options.api.admit(this.options.participantIdentity, this.options.trackSid, randomUUID())
    // A late admission never grants permission to resume ingestion after a stop or leave.
    if (!this.accepting) {
      if (this.graceful && !this.closed) this.trackPost(() => this.postEmpty(id))
      return
    }
    this.options.assertRunAuthority()
    this.options.assertMicrophone()
    this.current = { id, samples: 0 }
    if (this.connection && (this.now() - this.connectionStartedAt >= SOCKET_MAX_AGE_MS || this.socketTurns >= SOCKET_MAX_TURNS)) {
      // No unbounded completion history: rotate only with every old commit acknowledged.
      if (this.pending.size !== 0) throw new TranscriptionError("overflow")
      this.connection.close()
      this.connection = undefined
      clearTimeout(this.rotationTimer)
    }
    if (!this.connection) {
      const connection = await (this.options.connect ?? ProviderConnection.connect)({
        model: this.options.model, apiKey: this.options.apiKey,
        assertAuthority: () => this.assertFinalAuthority(),
        onFinal: (turn) => this.receiveFinal(turn),
        onFailure: (error) => this.fail(error),
      })
      if (!this.accepting || this.closed) { connection.close(); return }
      this.options.assertRunAuthority()
      this.options.assertMicrophone()
      this.connection = connection
      this.connectionStartedAt = this.now()
      this.socketTurns = 0
      this.rotationTimer = setTimeout(() => this.rotateIfIdle(), SOCKET_MAX_AGE_MS)
    }
    for (const frame of frames) this.append(frame)
  }

  private append(frame: Int16Array): void {
    if (!this.accepting || this.closed || !this.current || !this.connection) throw new TranscriptionError("stopped")
    this.options.assertRunAuthority()
    this.options.assertMicrophone()
    this.connection.appendAudio(frame)
    this.current.samples += frame.length
  }

  private commit(): void {
    const current = this.current
    this.current = undefined
    if (!current) return
    this.assertFinalAuthority()
    if (!this.connection || current.samples === 0) {
      this.trackPost(() => this.postEmpty(current.id))
      return
    }
    if (this.pending.size >= MAX_PENDING_TURNS) throw new TranscriptionError("overflow")
    // Manual finalize works best with real trailing silence; hard speech boundaries and
    // manual Stop add a finite 200ms zero tail, never more captured room audio.
    this.connection.appendAudio(new Int16Array(this.sampleRate / 5))
    const timer = setTimeout(() => this.fail(new TranscriptionError("provider")), FINAL_TIMEOUT_MS)
    this.pending.set(current.id, { timer, posting: false })
    this.socketTurns++
    this.connection.commitTurn(current.id)
  }

  private assertFinalAuthority(): void {
    if (this.closed) throw new TranscriptionError("stopped")
    this.options.assertRunAuthority()
    // A pre-admitted speaker can leave voice while its immutable turn completes.
    // The API independently fences current Space, destination and admitted attribution.
  }

  private receiveFinal(turn: FinalTurn): void {
    this.assertFinalAuthority()
    const pending = this.pending.get(turn.turnId)
    if (!pending || pending.posting) throw new TranscriptionError("protocol")
    pending.posting = true
    clearTimeout(pending.timer)
    this.trackPost(() => this.postFinal(turn).finally(() => {
      this.pending.delete(turn.turnId)
      this.maybeDrained()
    }))
  }

  private async postFinal(turn: FinalTurn): Promise<void> {
    // Idempotent delivery may retry a lost response once; no other turn or text is substituted.
    for (let attempt = 0; attempt < 2; attempt++) {
      this.assertFinalAuthority()
      try {
        await this.options.api.final(turn.turnId, turn.text)
        this.assertFinalAuthority()
        return
      } catch (error) {
        if (attempt === 1 || (error instanceof TranscriptionError && error.code !== "provider")) throw error
      }
    }
  }
  private async postEmpty(id: string): Promise<void> { await this.postFinal({ turnId: id, text: "" }) }
  private trackPost(post: () => Promise<void>): void {
    // Provider finals arrive in commit order. Retain that order through API retries
    // using the existing bounded posting ownership, while capture keeps consuming.
    const predecessor = [...this.posting].at(-1)
    const operation = predecessor ? predecessor.then(post) : post()
    this.posting.add(operation)
    void operation.catch((error: unknown) => { if (!this.closed) this.fail(error) }).finally(() => {
      this.posting.delete(operation)
      this.maybeDrained()
    })
  }
  private maybeDrained(): void {
    this.rotateIfIdle()
    if (!this.accepting && !this.current && this.pending.size === 0 && this.posting.size === 0) this.drainResolve?.()
  }
  private rotateIfIdle(): void {
    if (!this.accepting || !this.connection || this.current || this.pending.size || this.posting.size
      || (this.now() - this.connectionStartedAt < SOCKET_MAX_AGE_MS && this.socketTurns < SOCKET_MAX_TURNS)) return
    this.connection.close()
    this.connection = undefined
    clearTimeout(this.rotationTimer)
    this.rotationTimer = undefined
  }
  private safe(error: unknown): TranscriptionError {
    return error instanceof TranscriptionError ? error : new TranscriptionError("provider")
  }
  private fail(error: unknown): void {
    if (this.closed) return
    this.discard()
    this.options.onFailure(this.safe(error))
  }

  // This barrier is synchronous. Its promise represents bounded completion of accepted work.
  stop(graceful: boolean): Promise<void> {
    if (this.closePromise) {
      if (!graceful) this.discard()
      return this.closePromise
    }
    this.accepting = false
    this.graceful = graceful
    this.queue.close()
    this.segmenter.stop()
    if (!graceful) { this.discard(); this.closePromise = Promise.resolve(); return this.closePromise }
    this.closePromise = this.finishGraceful()
    return this.closePromise
  }
  private async finishGraceful(): Promise<void> {
    // Inference/admit/connect can be pending; late results are checked before all writes.
    await this.consumer
    if (this.closed) return
    this.commit()
    if (this.pending.size || this.posting.size) {
      await new Promise<void>((resolve) => {
        this.drainResolve = resolve
        this.drainTimer = setTimeout(resolve, FINAL_TIMEOUT_MS)
        this.maybeDrained()
      })
    }
    this.discard()
  }
  private discard(): void {
    if (this.closed) return
    this.closed = true
    this.accepting = false
    this.queue.close()
    this.segmenter.stop()
    this.connection?.close()
    this.connection = undefined
    this.current = undefined
    for (const pending of this.pending.values()) clearTimeout(pending.timer)
    this.pending.clear()
    clearTimeout(this.drainTimer)
    clearTimeout(this.processingTimer)
    clearTimeout(this.rotationTimer)
    this.options.detector.close()
    this.drainResolve?.()
  }
}
