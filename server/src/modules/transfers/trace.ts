import { AsyncLocalStorage } from "node:async_hooks"
import { Log, LogLevel } from "@in/server/utils/log"

/**
 * Per-transfer cost accounting. SQL statements are counted by the database
 * logger and storage operations by the counting store wrappers, both into the
 * scopes active in the current async context. Transaction BEGIN/COMMIT are not
 * statements here; every query the ORM issues is.
 */
export type TransferCounters = {
  sqlStatements: number
  storagePut: number
  storageGet: number
  storageDelete: number
}

type CounterScope = {
  readonly counters: TransferCounters
  readonly parent: CounterScope | undefined
}

const scopes = new AsyncLocalStorage<CounterScope>()

export const emptyTransferCounters = (): TransferCounters => ({
  sqlStatements: 0,
  storagePut: 0,
  storageGet: 0,
  storageDelete: 0,
})

/** Runs `operation` with `counters` receiving every statement and storage operation it causes. */
export const withTransferCounters = <T>(counters: TransferCounters, operation: () => T): T =>
  scopes.run({ counters, parent: scopes.getStore() }, operation)

/** Counts only what `operation` causes, still reporting to enclosing scopes. */
export const countTransferWork = async <T>(
  operation: () => Promise<T>,
): Promise<{ value: T; counters: TransferCounters }> => {
  const counters = emptyTransferCounters()
  const value = await withTransferCounters(counters, operation)
  return { value, counters }
}

export const recordSqlStatement = (): void => {
  for (let scope = scopes.getStore(); scope; scope = scope.parent) scope.counters.sqlStatements += 1
}

export type StorageOperation = "put" | "get" | "delete"

export const recordStorageOperation = (operation: StorageOperation): void => {
  for (let scope = scopes.getStore(); scope; scope = scope.parent) {
    if (operation === "put") scope.counters.storagePut += 1
    else if (operation === "get") scope.counters.storageGet += 1
    else scope.counters.storageDelete += 1
  }
}

export type TransferDirection = "upload" | "download"
export type TransferCarrier = "v2" | "v3"
export type TransferOutcome = "complete" | "failed" | "canceled" | "eof" | "abandoned"

type TransferTrace = {
  readonly direction: TransferDirection
  readonly carrier: TransferCarrier
  readonly startedAt: number
  readonly counters: TransferCounters
  bytes: number
  parts: number
  retries: number
  inFlightBytes: number
  peakInFlightBytes: number
}

const MAX_OPEN_TRACES = 4_096
const log = new Log("transfers", LogLevel.INFO)

/**
 * One line per finished transfer, without file, message, user or session
 * identifiers. Keys are process-local and never logged.
 */
export class TransferTraces {
  readonly #open = new Map<string, TransferTrace>()

  constructor(
    private readonly emit: (line: Record<string, unknown>) => void = (line) => {
      log.info(`TRANSFER_TRACE ${JSON.stringify(line)}`)
    },
    private readonly now: () => number = () => performance.now(),
  ) {}

  /** Returns the open trace for `key`, starting one if needed. */
  touch(key: string, direction: TransferDirection, carrier: TransferCarrier): TransferTrace {
    const existing = this.#open.get(key)
    if (existing) {
      this.#open.delete(key)
      this.#open.set(key, existing)
      return existing
    }
    const trace: TransferTrace = {
      direction,
      carrier,
      startedAt: this.now(),
      counters: emptyTransferCounters(),
      bytes: 0,
      parts: 0,
      retries: 0,
      inFlightBytes: 0,
      peakInFlightBytes: 0,
    }
    this.#open.set(key, trace)
    while (this.#open.size > MAX_OPEN_TRACES) {
      const oldest = this.#open.keys().next().value
      if (oldest === undefined) break
      this.finish(oldest, "abandoned")
    }
    return trace
  }

  get(key: string): TransferTrace | undefined {
    return this.#open.get(key)
  }

  /** Counts a part's bytes in flight for the duration of `operation` and attributes its work. */
  async part<T>(key: string, trace: TransferTrace, bytes: number, operation: () => Promise<T>): Promise<T> {
    trace.inFlightBytes += bytes
    trace.peakInFlightBytes = Math.max(trace.peakInFlightBytes, trace.inFlightBytes)
    try {
      return await withTransferCounters(trace.counters, operation)
    } finally {
      trace.inFlightBytes -= bytes
      if (!this.#open.has(key)) this.#open.set(key, trace)
    }
  }

  finish(key: string, outcome: TransferOutcome): void {
    const trace = this.#open.get(key)
    if (!trace) return
    this.#open.delete(key)
    try {
      this.emit({
        direction: trace.direction,
        carrier: trace.carrier,
        bytes: trace.bytes,
        parts: trace.parts,
        durationMs: Math.round(this.now() - trace.startedAt),
        peakInFlightBytes: trace.peakInFlightBytes,
        sqlStatements: trace.counters.sqlStatements,
        storageOps: {
          put: trace.counters.storagePut,
          get: trace.counters.storageGet,
          delete: trace.counters.storageDelete,
        },
        retries: trace.retries,
        outcome,
      })
    } catch {
      // Telemetry never affects a transfer.
    }
  }

  get openCount(): number {
    return this.#open.size
  }
}

export const transferTraces = new TransferTraces()
