import type { BatchTranscriber } from "./batch.js"
import type { Model } from "./protocol.js"
import type { TurnSpool } from "./spool.js"

export interface LateFinalApi { late(segmentId: string, text: string): Promise<void> }
export type SpoolRecoveryOptions = Readonly<{
  spool: TurnSpool; api: LateFinalApi; transcribe: BatchTranscriber;
  apiKey: (model: Model) => string | undefined;
  intervalMs?: number; staleMs?: number; now?: () => number;
}>

// A turn whose owner stopped refreshing it for a minute belongs to recovery.
const STALE_MS = 60_000
// The API accepts late finals for a day; older speech is deleted unsent.
const LATE_WINDOW_MS = 24 * 60 * 60 * 1000
const RETRY_BASE_MS = 15_000
const RETRY_MAX_MS = 10 * 60 * 1000

/**
 * Drains the spool once per worker process: turns handed off by a speaker, turns left by an
 * ended, failed or restarted room process. Each is batch transcribed and stored as a late final,
 * oldest first, with jittered backoff per turn while the provider or API is unreachable.
 */
export class SpoolRecovery {
  private timer: NodeJS.Timeout | undefined
  private draining: Promise<void> | undefined
  private readonly retries = new Map<string, { attempts: number; nextAtMs: number }>()
  private readonly now: () => number

  constructor(private readonly options: SpoolRecoveryOptions) {
    this.now = options.now ?? Date.now
  }

  start(): void {
    this.timer = setInterval(() => { void this.drain() }, this.options.intervalMs ?? 15_000)
    void this.drain()
  }

  async stop(): Promise<void> {
    clearInterval(this.timer)
    await this.draining
  }

  drain(): Promise<void> {
    this.draining ??= this.drainOnce().finally(() => { this.draining = undefined })
    return this.draining
  }

  private async drainOnce(): Promise<void> {
    let turns
    try { turns = this.options.spool.list() } catch { return }
    for (const turn of turns) {
      const now = this.now()
      if (now - turn.admittedAtMs > LATE_WINDOW_MS) { this.forget(turn.segmentId); continue }
      if (!turn.handoff && now - turn.touchedAtMs < (this.options.staleMs ?? STALE_MS)) continue
      const retry = this.retries.get(turn.segmentId)
      if (retry && retry.nextAtMs > now) continue
      const apiKey = this.options.apiKey(turn.model)
      if (!apiKey) continue
      try {
        const text = await this.options.transcribe(turn.model, apiKey, this.options.spool.read(turn.segmentId), turn.sampleRate)
        await this.options.api.late(turn.segmentId, text)
        this.forget(turn.segmentId)
      } catch {
        const attempts = (retry?.attempts ?? 0) + 1
        const ceiling = Math.min(RETRY_MAX_MS, RETRY_BASE_MS * 2 ** Math.min(attempts - 1, 10))
        this.retries.set(turn.segmentId, { attempts, nextAtMs: this.now() + ceiling / 2 + Math.random() * ceiling / 2 })
      }
    }
  }

  private forget(segmentId: string): void {
    this.options.spool.remove(segmentId)
    this.retries.delete(segmentId)
  }
}
