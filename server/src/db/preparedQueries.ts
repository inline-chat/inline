import type postgres from "postgres"

// Bound automatically retained SQL/type signatures per pool. Once full, new shapes keep
// postgres.js's unprepared behavior; existing hot shapes still reuse their plans.
export const MAX_PREPARED_QUERY_SHAPES = 256
const MAX_QUERY_LENGTH = 32_768
const MAX_PARAMETERS = 301
const installed = new WeakSet<postgres.Sql>()
type TransactionCallback<T> = (sql: postgres.TransactionSql) => T | Promise<T>

/** Drizzle uses unsafe(), whose call-level default disables preparation even
 * when the pool enables it. Apply the same bounded policy to borrowed/transaction
 * clients, including savepoints. Cache plans only, never rows or authority.
 * Requires protocol-level prepared statement support when using PgBouncer. */
export function prepareQueries(client: postgres.Sql): void {
  const shapes = new Set<string>()
  const wrap = <T extends postgres.Sql>(scope: T): T => {
    if (installed.has(scope)) return scope
    installed.add(scope)
    const unsafe = scope.unsafe
    scope.unsafe = (query, parameters, options) => {
      if (options?.prepare !== undefined || !parameters?.length || parameters.length > MAX_PARAMETERS ||
          query.length > MAX_QUERY_LENGTH || !/^\s*(select|insert|update|delete|with)\b/i.test(query)) {
        return unsafe(query, parameters, options)
      }
      // Match the driver's ordinary scalar type categories. Custom typed/array
      // parameters retain their original execution path rather than admitting
      // unbounded type variants under one SQL-text entry.
      const types = parameters.map(parameterType)
      if (types.some((type) => type === undefined)) return unsafe(query, parameters, options)
      const signature = `${types.join(",")}\0${query}`
      const prepare = shapes.has(signature) || shapes.size < MAX_PREPARED_QUERY_SHAPES
      if (prepare) shapes.add(signature)
      return unsafe(query, parameters, { ...options, prepare })
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
  if (value instanceof Date) return 1184
  if (value instanceof Uint8Array) return 17
  if (typeof value === "boolean") return 16
  if (typeof value === "bigint") return 20
  if (value === null || typeof value === "string" || typeof value === "number") return 0
  return undefined
}
