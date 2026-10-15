import type postgres from "postgres"
import { accessQueryComment } from "./databaseDiagnostics"

// postgres.js retains admitted names until the physical connection closes. Do not
// pretend that evicting an application entry would deallocate those statements.
export const MAX_PREPARED_QUERY_SHAPES = 200
export const MAX_BROAD_PREPARED_QUERY_SHAPES = 100
export type PreparedQueryPolicy = { mode: "access" | "all-custom" }
const accessComments = [accessQueryComment("sync.replay"), accessQueryComment("sync.sidecars")]
const MAX_QUERY_LENGTH = 32_768
const MAX_PARAMETERS = 301
const installed = new WeakSet<postgres.Sql>()
type TransactionCallback<T> = (sql: postgres.TransactionSql) => T | Promise<T>

/** Drizzle uses unsafe(), whose call-level default disables preparation even
 * when the pool enables it. Apply the same bounded policy to borrowed/transaction
 * clients, including savepoints. Cache plans only, never rows or authority.
 * Broad preparation requires force_custom_plan on every backend serving the
 * application role. The connection policy activates it only after startup checks.
 * Requires protocol-level prepared statement support when using PgBouncer. */
export function prepareQueries(client: postgres.Sql, policy: PreparedQueryPolicy = { mode: "access" }): void {
  const shapes = new Set<string>()
  const broadShapes = new Set<string>()
  // Only candidates are evicted: they have never created retained statements.
  const candidates = new Set<string>()
  const wrap = <T extends postgres.Sql>(scope: T): T => {
    if (installed.has(scope)) return scope
    installed.add(scope)
    const unsafe = scope.unsafe
    scope.unsafe = (query, parameters, options) => {
      if (options?.prepare !== undefined || !parameters?.length || parameters.length > MAX_PARAMETERS ||
          query.length > MAX_QUERY_LENGTH || !/^\s*(select|insert|update|delete|with)\b/i.test(query)) {
        return unsafe(query, parameters, options)
      }
      const access = accessComments.some((comment) => query.trimEnd().endsWith(comment))
      if (!access && policy.mode !== "all-custom") return unsafe(query, parameters, options)
      // Match the driver's ordinary scalar/array type categories. Custom typed
      // parameters retain their original execution path rather than admitting
      // unbounded type variants under one SQL-text entry.
      const types = parameters.map(parameterType)
      if (types.some((type) => type === undefined)) return unsafe(query, parameters, options)
      const signature = `${types.join(",")}\0${query}`
      if (shapes.has(signature)) return unsafe(query, parameters, { ...options, prepare: true })
      // In broad mode leave half the budget for replay access, even when many
      // variable-length IN queries arrive first. Default access mode has all 200.
      const capacity = shapes.size < MAX_PREPARED_QUERY_SHAPES &&
        (access || broadShapes.size < MAX_BROAD_PREPARED_QUERY_SHAPES)
      if (!capacity) return unsafe(query, parameters, options)
      if (!access && !candidates.has(signature)) {
        candidates.add(signature)
        if (candidates.size > MAX_PREPARED_QUERY_SHAPES) candidates.delete(candidates.values().next().value!)
        return unsafe(query, parameters, options)
      }
      candidates.delete(signature)
      shapes.add(signature)
      if (!access) broadShapes.add(signature)
      return unsafe(query, parameters, { ...options, prepare: true })
    }
    if (typeof scope.begin === "function") {
      const begin = scope.begin
      scope.begin = <R>(first: string | TransactionCallback<R>, callback?: TransactionCallback<R>) => {
        if (typeof first === "function") return begin((tx) => first(wrap(tx)))
        if (!callback) throw new Error("Missing transaction callback")
        return begin(first, (tx) => callback(wrap(tx)))
      }
    }
    if ("savepoint" in scope && typeof scope.savepoint === "function") {
      const savepoint = scope.savepoint as postgres.TransactionSql["savepoint"]
      scope.savepoint = <R>(first: string | TransactionCallback<R>, callback?: TransactionCallback<R>) => {
        if (typeof first === "function") return savepoint((tx) => first(wrap(tx)))
        if (!callback) throw new Error("Missing savepoint callback")
        return savepoint(first, (tx) => callback(wrap(tx)))
      }
    }
    if (typeof scope.reserve === "function") {
      const reserve = scope.reserve
      scope.reserve = async () => wrap(await reserve())
    }
    return scope
  }
  wrap(client)
}

function parameterType(value: unknown): number | undefined {
  // postgres.js infers ordinary arrays from their first element. Bound the
  // traversal so malformed/cyclic inputs do not recurse inside this policy.
  for (let depth = 0; Array.isArray(value); depth++) {
    if (depth >= 32) return undefined
    value = value[0] ?? null
  }
  if (value instanceof Date) return 1184
  if (value instanceof Uint8Array) return 17
  if (typeof value === "boolean") return 16
  if (typeof value === "bigint") return 20
  if (value === null || typeof value === "string" || typeof value === "number") return 0
  return undefined
}
