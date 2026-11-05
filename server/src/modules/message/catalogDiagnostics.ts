import { emptyTransferCounters, withTransferCounters } from "@in/server/modules/transfers/trace"

const clients = ["ios", "macos", "web", "api", "android", "windows", "linux", "cli", "unknown"] as const
type Client = typeof clients[number]
type Carrier = "v2" | "v3" | "unknown"
type Account = "bot" | "human" | "unknown"

type CatalogRequest = { clientType?: string; version?: number; isBot?: boolean; includeSubthreads: boolean }
type CatalogResult = { chats: readonly unknown[]; dialogs: readonly unknown[]; messages: readonly unknown[]; users: readonly unknown[]; spaces: readonly unknown[] }
export type CatalogWork = { prepareMs: number; snapshotMs: number; candidateChats: number; preparationCandidates: number }
type Sample = {
  client: Client; carrier: Carrier; account: Account; includeSubthreads: boolean
  completed: number; failed: number; totalMs: number; maxMs: number; atLeast500Ms: number
  sqlStatements: number; prepareMs: number; snapshotMs: number; candidateChats: number; preparationCandidates: number
  returnedChats: number; returnedDialogs: number; returnedMessages: number; returnedUsers: number; returnedSpaces: number
}

/** Only finite cohorts and numeric work totals survive a call. No identities,
 * SQL, input strings, response content or error objects are retained. */
export class CatalogDiagnostics {
  private readonly samples = new Map<string, Sample>()

  constructor(private readonly now: () => number = () => performance.now()) {}

  async observe<T extends CatalogResult>(request: CatalogRequest, run: (work: CatalogWork) => Promise<T>): Promise<T> {
    const client = clients.find((value) => value === request.clientType) ?? "unknown"
    const carrier: Carrier = request.version === 3 ? "v3" : request.version === 2 ? "v2" : "unknown"
    const account: Account = request.isBot === true ? "bot" : request.isBot === false ? "human" : "unknown"
    const key = `${client}.${carrier}.${account}.${request.includeSubthreads}`
    const work: CatalogWork = { prepareMs: 0, snapshotMs: 0, candidateChats: 0, preparationCandidates: 0 }
    const counters = emptyTransferCounters()
    const started = this.now()
    let result: T | undefined
    try {
      result = await withTransferCounters(counters, () => run(work))
      return result
    } finally {
      const durationMs = this.now() - started
      const sample = this.samples.get(key) ?? {
        client, carrier, account, includeSubthreads: request.includeSubthreads,
        completed: 0, failed: 0, totalMs: 0, maxMs: 0, atLeast500Ms: 0,
        sqlStatements: 0, prepareMs: 0, snapshotMs: 0, candidateChats: 0, preparationCandidates: 0,
        returnedChats: 0, returnedDialogs: 0, returnedMessages: 0, returnedUsers: 0, returnedSpaces: 0,
      }
      sample.completed += 1
      sample.failed += Number(result === undefined)
      sample.totalMs += durationMs
      sample.maxMs = Math.max(sample.maxMs, durationMs)
      sample.atLeast500Ms += Number(durationMs >= 500)
      sample.sqlStatements += counters.sqlStatements
      sample.prepareMs += work.prepareMs
      sample.snapshotMs += work.snapshotMs
      sample.candidateChats += work.candidateChats
      sample.preparationCandidates += work.preparationCandidates
      sample.returnedChats += result?.chats.length ?? 0
      sample.returnedDialogs += result?.dialogs.length ?? 0
      sample.returnedMessages += result?.messages.length ?? 0
      sample.returnedUsers += result?.users.length ?? 0
      sample.returnedSpaces += result?.spaces.length ?? 0
      this.samples.set(key, sample)
    }
  }

  drain(): Sample[] {
    const rows = Array.from(this.samples.values())
    this.samples.clear()
    return rows
  }
}

export const catalogDiagnostics = new CatalogDiagnostics()

/** The database lifecycle starts one reporter and flushes it at shutdown. */
export function startCatalogDiagnostics(
  emit: (row: Sample & { windowMs: number }) => void,
  diagnostics = catalogDiagnostics,
  intervalMs = 60_000,
) {
  let lastFlush = performance.now()
  const flush = () => {
    const now = performance.now()
    const windowMs = now - lastFlush
    lastFlush = now
    for (const row of diagnostics.drain()) {
      try { emit({ ...row, windowMs }) } catch { /* Telemetry cannot fail catalog reads or shutdown. */ }
    }
  }
  const timer = setInterval(flush, intervalMs)
  timer.unref()
  return () => { clearInterval(timer); flush() }
}
