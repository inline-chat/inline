import type postgres from "postgres"
import { accessQueryComment } from "./databaseDiagnostics"

const comments = [accessQueryComment("sync.replay"), accessQueryComment("sync.sidecars")]

/**
 * Drizzle's postgres-js adapter uses unsafe(), which disables preparation even
 * when the client enables it. Opt in only user replay's access queries on the
 * shared client: at most 100 chat IDs repeated in three clauses plus one user.
 * The two sources therefore produce at most 200 statement shapes per client.
 * Larger batches and transaction-owned clients retain their existing behavior.
 * This caches plans, never authorization results. PgBouncer must support
 * protocol-level prepared statements (production max_prepared_statements=200).
 */
export function prepareAccessQueries(client: postgres.Sql): void {
  const unsafe = client.unsafe
  client.unsafe = (query, parameters, options) => unsafe(query, parameters,
    options?.prepare === undefined && parameters !== undefined && parameters.length <= 301 &&
      comments.some((comment) => query.trimEnd().endsWith(comment))
      ? { ...options, prepare: true }
      : options)
}
