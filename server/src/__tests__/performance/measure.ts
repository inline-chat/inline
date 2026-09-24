import { createHash } from "node:crypto"
import type postgres from "postgres"

export type SqlCounts = {
  commands: number
  catalogCommands: number
  transactions: number
  connections: number
  shapes: Record<string, number>
}

export type WireCounts = {
  frames: Record<string, number>
  exchangeBoundaries: number
  clientBytes: number
  serverBytes: number
}

export type Sample = {
  operationMs: number
  settledMs: number
  sql: SqlCounts
  commandsBeforeReturn: number
  wire?: WireCounts
}

type DebugOptions = Pick<postgres.Options<{}>, "debug">
type WireMeter = { reset(): void; snapshot(): WireCounts }
const active = new WeakSet<DebugOptions>()

// A statement fingerprint is useful for finding repetition, without writing SQL
// text or bind values to artifacts. Scrub literals before hashing as well.
export function statementShape(query: string): string {
  const normalized = query
    .replace(/\$([A-Za-z_][A-Za-z_0-9]*)?\$[\s\S]*?\$\1\$/g, "?")
    .replace(/'(?:''|[^'])*'/g, "?")
    .replace(/\b\d+(?:\.\d+)?\b/g, "?")
    .replace(/\s+/g, " ").trim()
  const kind = normalized.match(/^(?:\/\*[\s\S]*?\*\/\s*)*([a-z]+)/i)?.[1]?.toUpperCase() ?? "OTHER"
  return `${kind}:${createHash("sha256").update(normalized).digest("hex").slice(0, 16)}`
}

/** One isolated scenario at a time. Debug callbacks are connection-scoped, so
 * AsyncLocalStorage cannot reliably attribute queued queries to their callers. */
export async function measureOperation(
  options: DebugOptions,
  run: () => Promise<void>,
  drain: () => Promise<void>,
  wire?: WireMeter,
): Promise<Sample> {
  if (active.has(options)) throw new Error("Overlapping database measurements are not supported")
  active.add(options)
  const previous = options.debug
  const sql: SqlCounts = { commands: 0, catalogCommands: 0, transactions: 0, connections: 0, shapes: {} }
  const connections = new Set<number>()
  options.debug = (connection, query) => {
    // Postgres.js discovers array types once per connection. Report this setup
    // separately; it is not application SQL and depends on pool warmth.
    if (/^\s*select\s+b\.oid,\s*b\.typarray\s+from\s+pg_catalog\.pg_type\s+a\s+left\s+join/i.test(query)) { sql.catalogCommands++; return }
    sql.commands++
    if (/^\s*(begin|commit|rollback|savepoint|release)\b/i.test(query)) sql.transactions++
    connections.add(connection)
    const shape = statementShape(query)
    sql.shapes[shape] = (sql.shapes[shape] ?? 0) + 1
  }
  try {
    wire?.reset()
    const start = performance.now()
    const errors: unknown[] = []
    try { await run() } catch (error) { errors.push(error) }
    const operationMs = performance.now() - start
    const commandsBeforeReturn = sql.commands
    // Always drain on failure too, before restoring the observer or resetting DB.
    try { await drain() } catch (error) { errors.push(error) }
    const settledMs = performance.now() - start
    sql.connections = connections.size
    if (errors.length) throw new AggregateError(errors, "Measured operation or its background work failed")
    return { operationMs, settledMs, commandsBeforeReturn, sql, ...(wire ? { wire: wire.snapshot() } : {}) }
  } finally {
    options.debug = previous
    active.delete(options)
  }
}

export function assertQueryBudget(name: string, sample: Sample, maxCommands: number): void {
  if (!Number.isInteger(maxCommands) || maxCommands < 1) throw new Error(`${name}: invalid database command budget`)
  if (sample.sql.commands === 0) throw new Error(`${name}: no database commands observed; check the measurement boundary`)
  if (sample.sql.commands > maxCommands) {
    throw new Error(`${name}: ${sample.sql.commands} database commands exceed budget ${maxCommands}. ` +
      "Verify correctness and explain the additional work; do not automatically regenerate budgets.")
  }
}

export function distribution(values: readonly number[]) {
  if (!values.length || values.some((value) => !Number.isFinite(value) || value < 0)) {
    throw new Error("Expected nonempty, finite, nonnegative samples")
  }
  const sorted = [...values].sort((a, b) => a - b)
  const middle = Math.floor(sorted.length / 2)
  return {
    min: sorted[0]!,
    median: sorted.length % 2 ? sorted[middle]! : (sorted[middle - 1]! + sorted[middle]!) / 2,
    // A small smoke run is useful, but is not a tail-latency estimate.
    p95: sorted.length >= 20 ? sorted[Math.ceil(sorted.length * 0.95) - 1]! : null,
    max: sorted.at(-1)!,
  }
}
