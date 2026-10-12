import { sql, type SQL } from "drizzle-orm"
import { ReplayProgress, type ReplayProgressOperation } from "./replayProgress"

export const accessQuerySources = [
  "authorization", "sync.replay", "sync.sidecars", "repair.chat",
  "chats.list", "messages.send", "realtime.delivery",
] as const
export type AccessQuerySource = typeof accessQuerySources[number]

type ReplayScope = "user" | "space" | "chat"
type ReplayPhase = "total" | "resolve" | "fetch" | "inflate" | "sidecars"
type Operation = `access.${AccessQuerySource}` | `replay.${ReplayScope}.${ReplayPhase}` | ReplayProgressOperation | "transaction.total" | "transaction.admission"
type Sample = {
  completed: number
  failed: number
  totalMs: number
  maxMs: number
  atLeast100Ms: number
  atLeast500Ms: number
  workItems: number
  inFlight: number
  peakInFlight: number
}

const emptySample = (inFlight = 0): Sample => ({
  completed: 0, failed: 0, totalMs: 0, maxMs: 0,
  atLeast100Ms: 0, atLeast500Ms: 0, workItems: 0,
  inFlight, peakInFlight: inFlight,
})

/** Fixed operation names only. Never receives SQL, bindings, identities or errors. */
export class DatabaseDiagnostics {
  private readonly samples = new Map<Operation, Sample>()

  constructor(private readonly now: () => number = performance.now.bind(performance)) {}

  private sample(operation: Operation): Sample {
    let sample = this.samples.get(operation)
    if (!sample) { sample = emptySample(); this.samples.set(operation, sample) }
    return sample
  }

  record(operation: Operation, durationMs: number, workItems = 0, failed = false): void {
    const sample = this.sample(operation)
    sample.completed += 1
    sample.failed += Number(failed)
    sample.totalMs += durationMs
    sample.maxMs = Math.max(sample.maxMs, durationMs)
    sample.atLeast100Ms += Number(durationMs >= 100)
    sample.atLeast500Ms += Number(durationMs >= 500)
    sample.workItems += workItems
  }

  async observe<T>(operation: Operation, workItems: number, run: () => PromiseLike<T>): Promise<T> {
    const sample = this.sample(operation)
    sample.inFlight += 1
    sample.peakInFlight = Math.max(sample.peakInFlight, sample.inFlight)
    const started = this.now()
    let failed = true
    try {
      const result = await run()
      failed = false
      return result
    } finally {
      // A reporting interval can rotate while this operation is pending.
      this.sample(operation).inFlight -= 1
      this.record(operation, this.now() - started, workItems, failed)
    }
  }

  drain() {
    const rows = Array.from(this.samples, ([operation, sample]) => ({ operation, ...sample }))
    this.samples.clear()
    for (const row of rows) {
      if (row.inFlight > 0) this.samples.set(row.operation, emptySample(row.inFlight))
    }
    return rows
  }
}

export const databaseDiagnostics = new DatabaseDiagnostics()
export const replayProgress = new ReplayProgress((operation, workItems) => databaseDiagnostics.record(operation, 0, workItems))

/** One process-owned reporter; reporting failures never affect database work. */
export const startDatabaseDiagnostics = (
  emit: (row: ReturnType<DatabaseDiagnostics["drain"]>[number] & { windowMs: number }) => void,
  diagnostics = databaseDiagnostics,
  intervalMs = 60_000,
) => {
  let lastFlush = performance.now()
  const flush = () => {
    const now = performance.now()
    const windowMs = now - lastFlush
    lastFlush = now
    for (const row of diagnostics.drain()) {
      try { emit({ ...row, windowMs }) } catch { /* Best-effort telemetry. */ }
    }
  }
  const timer = setInterval(flush, intervalMs)
  timer.unref()
  return () => { clearInterval(timer); flush() }
}

// Source is a code-owned finite union. Do not accept route paths or caller input.
export const accessQueryTag = (source: AccessQuerySource): SQL =>
  sql.raw(accessQueryComment(source))

export const accessQueryComment = (source: AccessQuerySource): string =>
  `/*application='inline-server',operation='chat_access',source='${source}'*/`
