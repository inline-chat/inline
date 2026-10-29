import { randomUUID } from "node:crypto"
import { BoundedPcmQueue } from "./pcm.js"
import { MAX_PENDING_TURNS, TranscriptionError, type FinalTurn, type Model } from "./protocol.js"
import { SpeechSegmenter } from "./segmenter.js"
import type { SpeechDetector } from "./silero.js"
import { ProviderConnection, type ProviderOptions } from "./socket.js"
import type { TurnSpoolWriter } from "./spool.js"
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
  idleCloseMs?: number;
  retryBaseMs?: number;
  maxBacklogMs?: number;
  spool?: TurnSpoolWriter;
  batchAfterMs?: number;
}>
type Turn = {
  id: string; frames: Int16Array[]; samples: number; closed: boolean; failures: number; capturedAt: number; spooled: boolean
}
const FINAL_TIMEOUT_MS = 5_000
const DRAIN_TIMEOUT_MS = 5_000
const SOCKET_MAX_AGE_MS = 9 * 60 * 1000
const SOCKET_MAX_TURNS = 900
// Providers bill open stream time, so a speaker's socket lives only while they talk. A quiet
// stretch closes it; their next turn reconnects while capture keeps buffering.
const SOCKET_IDLE_MS = 15_000
// Provider loss never stops capture. Reconnect with capped, jittered exponential backoff
// for as long as the run lasts, and resend the unfinished turn from its first sample.
const RETRY_BASE_MS = 500
const RETRY_MAX_MS = 30_000
// A turn the provider keeps failing on is retired empty rather than blocking the speaker.
const MAX_TURN_FAILURES = 5
// Speech buffered while the provider is unreachable (16 kHz mono: ~9.6 MB per speaker).
const MAX_BACKLOG_MS = 5 * 60 * 1000
// Real-time providers expect near real-time audio. Live speech already arrives at that pace;
// a turn sent more than a second after capture began (a resend or backlog) is paced, not burst.
const REPLAY_AFTER_MS = 1_000
const REPLAY_SPEED = 1.25
const REPLAY_HEADROOM_MS = 500
// With a spool, a closed turn still unsent a minute after capture goes to batch transcription
// instead of real-time replay, so a long outage cannot leave a speaker permanently behind.
const BATCH_AFTER_MS = 60_000
// Owners refresh spooled turns so recovery only takes turns whose process stopped caring.
const SPOOL_TOUCH_MS = 10_000

// Exactly one consumer owns each speaker's VAD and admission order; one sender owns provider
// order. Native RTC readers only push owned copies and never wait for inference or network I/O.
export class TrackWorker {
  readonly sampleRate: number
  private readonly queue: BoundedPcmQueue
  private readonly segmenter: SpeechSegmenter
  private readonly now: () => number
  private readonly consumer: Promise<void>
  private readonly sender: Promise<void>
  private accepting = true
  private closed = false
  private graceful = false
  private draining = false
  /** Admitted turns without a provider final, oldest first. The last one may still be capturing. */
  private readonly turns: Turn[] = []
  private backlogSamples = 0
  private connection: SpeechConnection | undefined
  private generation = 0
  private connectionStartedAt = 0
  private socketTurns = 0
  /** Leading turns committed on the current socket, awaiting finals in commit order. */
  private committed = 0
  /** The turn after the committed ones, partly streamed on the current socket. */
  private streaming: { sent: number; startedAt: number } | undefined
  private finalTimer: NodeJS.Timeout | undefined
  private idleTimer: NodeJS.Timeout | undefined
  private retryAttempt = 0
  private wake: (() => void) | undefined
  private endDelay: (() => void) | undefined
  private readonly posting = new Set<Promise<void>>()
  private closePromise: Promise<void> | undefined
  private drainResolve: (() => void) | undefined
  private drainTimer: NodeJS.Timeout | undefined
  private processingTimer: NodeJS.Timeout | undefined
  private touchTimer: NodeJS.Timeout | undefined

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
    this.sender = this.send().catch((error: unknown) => this.fail(error))
    const spool = options.spool
    if (spool) {
      this.touchTimer = setInterval(() => { for (const turn of this.turns) if (turn.spooled) spool.touch(turn.id) }, SPOOL_TOUCH_MS)
      this.touchTimer.unref()
    }
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
        else this.closeTurn()
      }
      } finally { clearTimeout(this.processingTimer); this.processingTimer = undefined }
    }
  }

  private get capturing(): Turn | undefined {
    const last = this.turns.at(-1)
    return last && !last.closed ? last : undefined
  }

  private async startTurn(frames: readonly Int16Array[]): Promise<void> {
    if (this.capturing) throw new TranscriptionError("overflow")
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
    const spooled = this.options.spool?.open(id, this.options.model, this.sampleRate) ?? false
    this.turns.push({ id, frames: [], samples: 0, closed: false, failures: 0, capturedAt: this.now(), spooled })
    for (const frame of frames) this.append(frame)
    this.notify()
  }

  private append(frame: Int16Array): void {
    const turn = this.capturing
    if (!this.accepting || this.closed || !turn) throw new TranscriptionError("stopped")
    this.options.assertRunAuthority()
    this.options.assertMicrophone()
    if ((this.backlogSamples + frame.length) * 1000 > (this.options.maxBacklogMs ?? MAX_BACKLOG_MS) * this.sampleRate)
      throw new TranscriptionError("overflow")
    if (turn.spooled && !this.options.spool!.append(turn.id, frame)) turn.spooled = false
    turn.frames.push(frame)
    turn.samples += frame.length
    this.backlogSamples += frame.length
    this.notify()
  }

  private closeTurn(): void {
    const turn = this.capturing
    if (!turn) return
    this.assertFinalAuthority()
    turn.closed = true
    if (turn.spooled) this.options.spool!.close(turn.id)
    this.notify()
  }

  /** The only provider writer: turns in admission order, at most two awaiting finals, across reconnects. */
  private async send(): Promise<void> {
    while (!this.closed) {
      const turn = this.turns[this.committed]
      if (!turn || this.committed >= MAX_PENDING_TURNS || (!this.accepting && !this.draining)) {
        if (!this.accepting && !this.draining && !this.turns.length) return
        await this.sleep()
        continue
      }
      clearTimeout(this.idleTimer)
      this.idleTimer = undefined
      if (this.committed === 0 && turn.spooled && turn.closed
        && this.now() - turn.capturedAt > (this.options.batchAfterMs ?? BATCH_AFTER_MS)) {
        this.handOff(turn)
        continue
      }
      if (turn.closed && turn.samples === 0) {
        // Finals retire in order, so an empty turn waits behind committed predecessors.
        if (this.committed === 0) this.retire(turn, "")
        else await this.sleep()
        continue
      }
      if (!this.connection) {
        if (this.retryAttempt > 0) await this.delay(this.backoff())
        if (!this.closed) await this.connect()
        continue
      }
      if (!this.streaming) {
        if (this.committed === 0
          && (this.now() - this.connectionStartedAt >= SOCKET_MAX_AGE_MS || this.socketTurns >= SOCKET_MAX_TURNS)) {
          // Rotate between turns, where nothing is committed on the old socket.
          this.closeConnection()
          continue
        }
        this.streaming = { sent: 0, startedAt: this.now() }
      }
      const streaming = this.streaming
      try {
        const replay = streaming.startedAt - turn.capturedAt > REPLAY_AFTER_MS
        const allowed = replay
          ? ((this.now() - streaming.startedAt) * REPLAY_SPEED + REPLAY_HEADROOM_MS) * this.sampleRate / 1000
          : Number.POSITIVE_INFINITY
        let delivered = turn.frames.slice(0, streaming.sent).reduce((sum, frame) => sum + frame.length, 0)
        while (streaming.sent < turn.frames.length && delivered < allowed) {
          this.assertFinalAuthority()
          const frame = turn.frames[streaming.sent]!
          this.connection.appendAudio(frame)
          delivered += frame.length
          streaming.sent++
        }
        if (streaming.sent < turn.frames.length) {
          await this.sleep(20)
          continue
        }
        if (!turn.closed) { await this.sleep(); continue }
        // Manual finalize works best with real trailing silence; hard speech boundaries and
        // manual Stop add a finite 200ms zero tail, never more captured room audio.
        this.connection.appendAudio(new Int16Array(this.sampleRate / 5))
        this.streaming = undefined
        this.committed++
        this.socketTurns++
        if (this.committed === 1) this.armFinalTimer()
        this.connection.commitTurn(turn.id)
      } catch (error) {
        if (!retryable(error)) throw error
        this.providerFailed(this.generation)
      }
    }
  }

  /** A final that never arrives is a provider failure: reconnect and resend. */
  private armFinalTimer(): void {
    clearTimeout(this.finalTimer)
    const generation = this.generation
    this.finalTimer = setTimeout(() => this.providerFailed(generation), FINAL_TIMEOUT_MS)
  }

  private async connect(): Promise<boolean> {
    const generation = ++this.generation
    try {
      const connection = await (this.options.connect ?? ProviderConnection.connect)({
        model: this.options.model, apiKey: this.options.apiKey,
        assertAuthority: () => this.assertFinalAuthority(),
        onFinal: (turn) => this.receiveFinal(turn, generation),
        onFailure: (error) => { if (retryable(error)) this.providerFailed(generation); else this.fail(error) },
      })
      if (this.closed || generation !== this.generation) { connection.close(); return false }
      try { this.assertFinalAuthority() } catch (error) { connection.close(); throw error }
      this.connection = connection
      this.connectionStartedAt = this.now()
      this.socketTurns = 0
      return true
    } catch (error) {
      if (!retryable(error)) throw error
      this.retryAttempt++
      return false
    }
  }

  /** Drop the socket and resend every unfinished turn on a fresh one. Capture is unaffected. */
  private providerFailed(generation: number): void {
    if (this.closed || generation !== this.generation) return
    this.closeConnection()
    this.retryAttempt++
    const oldest = this.turns[0]
    if (oldest && ++oldest.failures >= MAX_TURN_FAILURES && oldest.closed) {
      if (oldest.spooled) this.handOff(oldest)
      else this.retire(oldest, "")
    }
    this.notify()
  }

  /** Leave a spooled turn to batch recovery; its late final arrives after later live turns. */
  private handOff(turn: Turn): void {
    if (this.turns[0] !== turn || this.committed !== 0) throw new TranscriptionError("protocol")
    // A replay can cross the batch threshold after sending a prefix. Drop that socket
    // so the provider cannot include the abandoned prefix in the next live turn.
    this.closeConnection()
    this.turns.shift()
    this.backlogSamples -= turn.samples
    this.streaming = undefined
    this.options.spool!.handoff(turn.id)
    this.notify()
  }

  private backoff(): number {
    const ceiling = Math.min(RETRY_MAX_MS, (this.options.retryBaseMs ?? RETRY_BASE_MS) * 2 ** Math.min(this.retryAttempt, 16))
    return ceiling / 2 + Math.random() * ceiling / 2
  }

  private assertFinalAuthority(): void {
    if (this.closed) throw new TranscriptionError("stopped")
    this.options.assertRunAuthority()
    // A pre-admitted speaker can leave voice while its immutable turn completes.
    // The API independently fences current Space, destination and admitted attribution.
  }

  private receiveFinal(final: FinalTurn, generation: number): void {
    this.assertFinalAuthority()
    if (generation !== this.generation) return
    const turn = this.turns[0]
    if (!this.committed || turn?.id !== final.turnId) throw new TranscriptionError("protocol")
    this.retryAttempt = 0
    this.retire(turn, final.text)
  }

  private retire(turn: Turn, text: string): void {
    if (this.turns[0] !== turn) throw new TranscriptionError("protocol")
    this.turns.shift()
    this.backlogSamples -= turn.samples
    clearTimeout(this.finalTimer)
    this.finalTimer = undefined
    if (this.committed > 0) {
      this.committed--
      if (this.committed > 0) this.armFinalTimer()
    }
    this.trackPost(async () => {
      await this.postFinal({ turnId: turn.id, text })
      if (turn.spooled) this.options.spool!.remove(turn.id)
    })
    this.notify()
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
    // Finals retire in admission order. Retain that order through API retries
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
    this.scheduleIdleClose()
    if (!this.accepting && this.turns.length === 0 && this.posting.size === 0) this.drainResolve?.()
  }
  private scheduleIdleClose(): void {
    if (!this.accepting || !this.connection || this.turns.length || this.posting.size) return
    clearTimeout(this.idleTimer)
    this.idleTimer = setTimeout(() => {
      if (this.accepting && !this.turns.length && !this.posting.size) this.closeConnection()
    }, this.options.idleCloseMs ?? SOCKET_IDLE_MS)
  }
  private closeConnection(): void {
    this.connection?.close()
    this.connection = undefined
    this.generation++
    this.committed = 0
    this.streaming = undefined
    clearTimeout(this.finalTimer)
    this.finalTimer = undefined
    clearTimeout(this.idleTimer)
    this.idleTimer = undefined
  }

  private notify(): void {
    const wake = this.wake
    this.wake = undefined
    wake?.()
    if (!this.turns.length) this.maybeDrained()
  }
  private sleep(ms?: number): Promise<void> {
    return new Promise((resolve) => {
      const timer = ms === undefined ? undefined : setTimeout(() => { if (this.wake === done) this.wake = undefined; resolve() }, ms)
      const done = () => { clearTimeout(timer); resolve() }
      this.wake = done
    })
  }
  /** Backoff ignores new audio; only teardown ends it early. */
  private delay(ms: number): Promise<void> {
    return new Promise((resolve) => {
      const timer = setTimeout(done, ms)
      function done() { clearTimeout(timer); resolve() }
      this.endDelay = done
    })
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
    const capturing = this.turns.at(-1)
    if (capturing) capturing.closed = true
    this.draining = true
    this.notify()
    if (this.turns.length || this.posting.size) {
      await new Promise<void>((resolve) => {
        this.drainResolve = resolve
        this.drainTimer = setTimeout(resolve, DRAIN_TIMEOUT_MS)
        this.maybeDrained()
      })
    }
    this.discard()
    await this.sender
  }
  private discard(): void {
    if (this.closed) return
    this.closed = true
    this.accepting = false
    this.draining = false
    this.queue.close()
    this.segmenter.stop()
    this.closeConnection()
    this.turns.length = 0
    this.backlogSamples = 0
    clearTimeout(this.drainTimer)
    clearTimeout(this.processingTimer)
    clearInterval(this.touchTimer)
    this.options.detector.close()
    this.drainResolve?.()
    this.wake?.()
    this.endDelay?.()
  }
}

/** Socket loss, refusal, timeouts and send backpressure are provider weather, not run failures. */
function retryable(error: unknown): boolean {
  return error instanceof TranscriptionError && (error.code === "provider" || error.code === "overflow")
}
