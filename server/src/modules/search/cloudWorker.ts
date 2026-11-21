import { bootstrapSearchDocuments, requeueObsoleteSearchDocuments, runCloudSearchIndexBatch } from "./cloudIndex"
import { db } from "@in/server/db"
import { sql } from "drizzle-orm"
import { searchFailureClass } from "./cloudFailure"
import { Log } from "@in/server/utils/log"

const log = new Log("cloudSearch.worker")

/** One poll at a time; durable pending rows survive process restarts. */
export class CloudSearchWorker {
  private timer: ReturnType<typeof setTimeout> | undefined
  private inFlight: Promise<void> | undefined
  private stopped = false
  private started = false
  private nextBackfillCheck = 0
  private nextDelayMs = 1000

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
      // Live sends and edits get first claim. Reserve a quarter for history even under sustained traffic.
      const live = await runCloudSearchIndexBatch({ limit: 12 })
      if (process.env["CLOUD_MESSAGE_SEARCH_BACKFILL_ENABLED"] !== "false" && Date.now() >= this.nextBackfillCheck) {
        const complete = await bootstrapSearchDocuments()
        if (complete) {
          const repaired = await requeueObsoleteSearchDocuments()
          this.nextBackfillCheck = Date.now() + (repaired ? 1_000 : 60_000)
        }
      }
      const history = await runCloudSearchIndexBatch({ historicalOnly: true, limit: 4 })
      if (live.indexed === 12 || history.indexed === 4) this.nextDelayMs = 25
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
