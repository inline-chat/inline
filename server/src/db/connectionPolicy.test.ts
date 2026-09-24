import { describe, expect, test } from "bun:test"
import { assertQueryTimeouts, databaseConnectionPolicy, directDatabaseUrl, makeDatabaseClients, QUERY_TIMEOUTS, HEALTH_TIMEOUTS } from "./connectionPolicy"

const direct = "postgres://app:secret@db.example/test?sslmode=verify-full"
const pooled = "postgres://app:secret@db.example:6432/test?sslmode=verify-full"
const environment = { DATABASE_CONNECTION_MODE: "pgbouncer", DATABASE_DIRECT_URL: direct }

describe("database connection safety", () => {
  test("direct mode preserves the existing query and health timeout profiles", async () => {
    const clients = makeDatabaseClients(direct)
    try {
      expect(clients.queryClient.options.max).toBe(10)
      expect(clients.healthClient.options.max).toBe(1)
      expect(clients.queryClient.options.connection).toMatchObject(QUERY_TIMEOUTS)
      expect(clients.healthClient.options.connection).toMatchObject(HEALTH_TIMEOUTS)
      await clients.validateStartup() // Direct mode remains lazy; no network required.
    } finally { await clients.close() }
  })

  test("pooled startup omits unsupported GUCs while health retains its direct budgets", async () => {
    const clients = makeDatabaseClients(pooled, environment)
    try {
      expect(clients.queryClient.options.connection).toEqual({ application_name: "inline-server" })
      expect(clients.queryClient.options.prepare).toBe(true)
      expect(clients.queryClient.options.ssl).toBe("verify-full")
      expect(clients.healthClient.options.port).toEqual([5432])
      expect(clients.healthClient.options.connection).toMatchObject(HEALTH_TIMEOUTS)
    } finally { await clients.close() }
  })

  test("pooled mode and a separate direct URL must be explicit", () => {
    expect(() => databaseConnectionPolicy(pooled)).toThrow("explicit PgBouncer mode")
    expect(() => databaseConnectionPolicy(pooled, { DATABASE_CONNECTION_MODE: "pgbouncer" })).toThrow("DATABASE_DIRECT_URL")
    expect(() => databaseConnectionPolicy(direct, { DATABASE_CONNECTION_MODE: "typo" })).toThrow("must be direct or pgbouncer")
    expect(() => directDatabaseUrl({ ...environment, DATABASE_DIRECT_URL: pooled })).toThrow("direct PostgreSQL")
  })

  test("rejects wrong database, insecure TLS and injected startup parameters", () => {
    for (const url of [direct, pooled.replace("/test?", "/wrong?"), pooled.replace("db.example", "other.example"), pooled.replace("verify-full", "require"), pooled + "&sslmode=disable", pooled + "&statement_timeout=0", pooled + "&options=-c%20statement_timeout%3D0"]) {
      expect(() => databaseConnectionPolicy(url, environment)).toThrow()
    }
    expect(() => databaseConnectionPolicy(pooled, { ...environment, DATABASE_DIRECT_URL: direct + "&statement_timeout=0" })).toThrow()
    expect(() => databaseConnectionPolicy(pooled, { ...environment, DATABASE_DIRECT_URL: direct + "&sslmode=disable" })).toThrow()
  })

  test("migrations select only the explicit direct URL in pooled mode", () => {
    expect(directDatabaseUrl({ DATABASE_URL: direct })).toBe(direct)
    expect(directDatabaseUrl({ ...environment, DATABASE_URL: pooled })).toBe(direct)
    expect(() => directDatabaseUrl({ DATABASE_CONNECTION_MODE: "pgbouncer", DATABASE_URL: pooled })).toThrow()
    expect(() => directDatabaseUrl({ DATABASE_URL: pooled })).toThrow()
  })

  test("qualification rejects missing, disabled or changed timeout defaults", () => {
    const rows = Object.entries(QUERY_TIMEOUTS).map(([name, value]) => ({ name, setting: String(value), unit: "ms" }))
    expect(() => assertQueryTimeouts(rows)).not.toThrow()
    expect(() => assertQueryTimeouts(rows.slice(1))).toThrow()
    for (const setting of ["0", "30001", "NaN"]) {
      expect(() => assertQueryTimeouts([{ ...rows[0]!, setting }, ...rows.slice(1)])).toThrow()
    }
    expect(() => assertQueryTimeouts(rows.map((row) => ({ ...row, unit: "s" })))).toThrow()
  })

  test("invalid URL errors never include credentials", () => {
    for (const value of ["postgres://secret@", "https://user:secret@db.example/test"]) {
      expect(() => databaseConnectionPolicy(value)).toThrow("Database connection URL is invalid")
      try { databaseConnectionPolicy(value) }
      catch (error) { expect(String(error)).not.toContain("secret") }
    }
  })
})
