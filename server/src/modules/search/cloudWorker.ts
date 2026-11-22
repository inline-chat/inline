import { bootstrapSearchDocuments, requeueObsoleteSearchDocuments, runCloudSearchIndexBatch } from "./cloudIndex"
import { db } from "@in/server/db"
import { sql } from "drizzle-orm"
import { searchFailureClass } from "./cloudFailure"
import { Log } from "@in/server/utils/log"

const log = new Log("cloudSearch.worker")

const LIVE_BATCH = 12
// History (a backfill or a reindex after a profile change) is paced. An
// unpaced backfill of 300k messages held the PS-40 primary at 60-100% CPU,
// mostly in vacuum and GIN maintenance behind about 60 publishes a second.
// Each process indexes at most HISTORY_MAX_ROWS_PER_SECOND, and spends at most
// HISTORY_DUTY of its time on history, so a busy database, which slows the
// batches, lengthens the pauses after them. Every `all` process runs a worker
// (two today), so the fleet rate is a multiple of these.
export const HISTORY_BATCH = 16
const HISTORY_MAX_ROWS_PER_SECOND = 8
const HISTORY_DUTY = 0.2
const HISTORY_MAX_PAUSE_MS = 30_000

/** Milliseconds to wait after a history batch that examined `rows` in `elapsedMs`. */
export function historyPauseMs(rows: number, elapsedMs: number): number {
  if (rows === 0) return 0
  const byRate = (rows / HISTORY_MAX_ROWS_PER_SECOND) * 1000 - elapsedMs
  const byDuty = (elapsedMs * (1 - HISTORY_DUTY)) / HISTORY_DUTY
  return Math.min(HISTORY_MAX_PAUSE_MS, Math.max(0, byRate, byDuty))
}

/** One poll at a time; durable pending rows survive process restarts. */
export class CloudSearchWorker {
  private timer: ReturnType<typeof setTimeout> | undefined
  private inFlight: Promise<void> | undefined
  private stopped = false
  private started = false
  private nextBackfillCheck = 0
  private nextDelayMs = 1000
  /** History waits until then; live work never does. */
  historyNotBefore = 0
  private historyPending = false

  start(): void {
    if (this.started || this.stopped) return
    this.started = true
    this.schedule(0)
  }
  async stop(): Promise<void> {
    this.stopped = true
    if (this.timer) clearTimeout(this.timer)
    await this.inFlight
  }
  /** Run one bounded poll, coalescing concurrent calls; also useful to drain work without a timer. */
  pollOnce(): Promise<void> {
    if (this.stopped) return Promise.resolve()
    if (this.inFlight) return this.inFlight
    this.inFlight = this.poll().finally(() => {
      this.inFlight = undefined
    })
    return this.inFlight
  }
  private schedule(delay: number): void {
    if (this.stopped) return
    this.timer = setTimeout(() => {
      void this.pollOnce().finally(() => {
        this.schedule(this.nextDelayMs)
      })
    }, delay)
    this.timer.unref()
  }
  private async poll(): Promise<void> {
    this.nextDelayMs = 1000
    try {
      const [capture] = await db.execute<{ enabled: boolean }>(sql`select inline_search_capture_enabled() as enabled`)
      if (!capture?.enabled) {
        this.nextBackfillCheck = 0
        this.nextDelayMs = 5000
        return
      }
      // Live sends and edits are never paced, and never take historical rows.
      const live = await runCloudSearchIndexBatch({ liveOnly: true, limit: LIVE_BATCH })
      if (Date.now() >= this.historyNotBefore) {
        const started = performance.now()
        const history = await runCloudSearchIndexBatch({ historicalOnly: true, limit: HISTORY_BATCH })
        this.historyPending = history.examined === HISTORY_BATCH
        // Queue more history only once the queue drains, so a scan never outruns indexing.
        if (
          !this.historyPending &&
          process.env["CLOUD_MESSAGE_SEARCH_BACKFILL_ENABLED"] !== "false" &&
          Date.now() >= this.nextBackfillCheck
        ) {
          const complete = await bootstrapSearchDocuments()
          const repaired = complete ? await requeueObsoleteSearchDocuments() : 0
          if (complete && repaired === 0) this.nextBackfillCheck = Date.now() + 60_000
          // Look again promptly; the next empty history batch clears this.
          this.historyPending = true
        }
        this.historyNotBefore = Date.now() + historyPauseMs(history.examined, performance.now() - started)
      }
      const historyWait = this.historyNotBefore - Date.now()
      if (live.indexed === LIVE_BATCH) this.nextDelayMs = 25
      else if (this.historyPending) this.nextDelayMs = Math.min(1000, Math.max(25, historyWait))
    } catch (error) {
      log.warn("Search worker poll failed", { failure: searchFailureClass(error) })
    }
  }
}

export function startCloudSearchWorker(): CloudSearchWorker | null {
  if (process.env["CLOUD_MESSAGE_SEARCH_WORKER_ENABLED"] === "false") return null
  const worker = new CloudSearchWorker()
  worker.start()
  return worker
}
