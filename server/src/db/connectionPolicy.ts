import postgres from "postgres"

export const QUERY_TIMEOUTS = {
  statement_timeout: 30_000,
  lock_timeout: 5_000,
  idle_in_transaction_session_timeout: 15_000,
} as const
export const HEALTH_TIMEOUTS = {
  statement_timeout: 1_500,
  lock_timeout: 500,
  idle_in_transaction_session_timeout: 2_000,
} as const

type ConnectionMode = "direct" | "pgbouncer"
type DatabaseEnvironment = {
  [name: string]: string | undefined
  DATABASE_URL?: string
  DATABASE_DIRECT_URL?: string
  DATABASE_CONNECTION_MODE?: string
}

const parseDatabaseUrl = (value: string): URL => {
  try {
    const url = new URL(value)
    if (!["postgres:", "postgresql:"].includes(url.protocol) || !url.hostname) throw new Error()
    return url
  } catch {
    // Do not include a URL or parser cause: both can contain credentials.
    throw new Error("Database connection URL is invalid.")
  }
}

export const databaseConnectionMode = (value?: string): ConnectionMode => {
  if (value === undefined || value === "direct") return "direct"
  if (value === "pgbouncer") return value
  throw new Error("DATABASE_CONNECTION_MODE must be direct or pgbouncer.")
}

export const directDatabaseUrl = (environment: DatabaseEnvironment): string => {
  const mode = databaseConnectionMode(environment.DATABASE_CONNECTION_MODE)
  const value = environment.DATABASE_DIRECT_URL ?? (mode === "direct" ? environment.DATABASE_URL : undefined)
  if (!value) throw new Error(mode === "pgbouncer" ? "DATABASE_DIRECT_URL is required in PgBouncer mode." : "DATABASE_URL is required.")
  const direct = parseDatabaseUrl(value)
  if (direct.port === "6432") {
    throw new Error("Health checks and migrations require a direct PostgreSQL endpoint.")
  }
  // Standalone migration jobs may supply only a direct URL. When both URLs
  // exist, validate here so migrations and verification enforce the API's guard.
  if (environment.DATABASE_URL !== undefined && environment.DATABASE_DIRECT_URL !== undefined) {
    const query = parseDatabaseUrl(environment.DATABASE_URL)
    // Implicit database names depend on PGDATABASE/user defaults. Require an
    // explicit path for two endpoints, and preserve postgres.js's path encoding.
    if (!query.pathname.slice(1) || !direct.pathname.slice(1)) {
      throw new Error("Query and direct endpoints must explicitly name the database.")
    }
    for (const url of [query, direct]) {
      // postgres.js copies these URL options into the startup message, where
      // they override the identity parsed from the URL authority and path.
      if (url.searchParams.has("database") || url.searchParams.has("user")) {
        throw new Error("Database endpoint URLs must not override identity with query parameters.")
      }
    }
    if (direct.hostname !== query.hostname || direct.pathname !== query.pathname) {
      throw new Error("Query and direct endpoints must address the same host and database.")
    }
    if (mode === "direct" && (direct.port || "5432") !== (query.port || "5432")) {
      throw new Error("Query and direct endpoints must use the same port in direct mode.")
    }
  }
  return value
}

export const databaseConnectionPolicy = (databaseUrl: string, environment: DatabaseEnvironment = {}) => {
  const mode = databaseConnectionMode(environment.DATABASE_CONNECTION_MODE)
  const queryUrl = parseDatabaseUrl(databaseUrl)
  if (mode === "direct" && queryUrl.port === "6432") {
    throw new Error("Port 6432 requires explicit PgBouncer mode and timeout qualification.")
  }
  const healthUrl = directDatabaseUrl({ ...environment, DATABASE_URL: databaseUrl })
  if (mode === "pgbouncer") {
    const direct = parseDatabaseUrl(healthUrl)
    if ((direct.port || "5432") === (queryUrl.port || "5432")) {
      throw new Error("Pooled and direct endpoints must use distinct ports.")
    }
    // postgres.js turns unknown URL options into startup parameters. An allowlist
    // prevents reintroducing unsupported SET/options or overriding pool budgets.
    for (const url of [queryUrl, direct]) {
      if (url.searchParams.getAll("sslmode").length > 1) throw new Error("Database URL must not repeat sslmode.")
      for (const key of url.searchParams.keys()) {
        if (key !== "sslmode") throw new Error("PgBouncer mode URLs only support the sslmode query parameter.")
      }
    }
    const local = ["localhost", "127.0.0.1", "[::1]"].includes(queryUrl.hostname)
    if (!local && (queryUrl.searchParams.get("sslmode") !== "verify-full" || direct.searchParams.get("sslmode") !== "verify-full")) {
      throw new Error("Remote pooled and direct endpoints require sslmode=verify-full.")
    }
  }
  return { mode, queryUrl: databaseUrl, healthUrl }
}

type TimeoutRow = { name: string; setting: string; unit: string | null }
export const assertQueryTimeouts = (rows: readonly TimeoutRow[]): void => {
  for (const [name, expected] of Object.entries(QUERY_TIMEOUTS)) {
    const row = rows.find((row) => row.name === name)
    if (!row || row.unit !== "ms" || Number(row.setting) !== expected) {
      throw new Error(`PgBouncer role must enforce ${name}=${expected}ms before startup.`)
    }
  }
}

export const makeDatabaseClients = (databaseUrl: string, environment: DatabaseEnvironment = {}) => {
  const policy = databaseConnectionPolicy(databaseUrl, environment)
  const queryClient = postgres(policy.queryUrl, {
    max: 10, connect_timeout: 5, idle_timeout: 30,
    connection: {
      application_name: "inline-server",
      ...(policy.mode === "direct" ? QUERY_TIMEOUTS : {}),
    },
  })
  const healthClient = postgres(policy.healthUrl, {
    max: 1, connect_timeout: 2, idle_timeout: 30,
    connection: { application_name: "inline-health", ...HEALTH_TIMEOUTS },
  })
  const close = () => Promise.all([queryClient.end({ timeout: 5 }), healthClient.end({ timeout: 5 })]).then(() => {})
  const queryTimeoutSettings = () => queryClient<TimeoutRow[]>`
    select name, setting, unit from pg_settings
    where name in ('statement_timeout', 'lock_timeout', 'idle_in_transaction_session_timeout')
  `.execute()
  const checkHealth = () => {
    const direct = healthClient.unsafe(
      "SELECT (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::double precision AS database_time_millis",
    ).execute()
    if (policy.mode === "direct") return direct
    // A healthy direct endpoint must not hide a broken/queued pooled endpoint.
    // The health controller's existing deadline cancels both pending queries.
    const pooled = queryTimeoutSettings()
    return Object.assign(Promise.all([direct, pooled]).then(([clock, rows]) => {
      assertQueryTimeouts(rows)
      return clock
    }), { cancel: () => { try { direct.cancel() } finally { pooled.cancel() } } })
  }
  const validateStartup = async (): Promise<void> => {
    if (policy.mode === "direct") return
    const query = queryTimeoutSettings()
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      const rows = await Promise.race([
        query,
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => {
            reject(new Error("PgBouncer timeout qualification exceeded 5 seconds."))
            try { query.cancel() } catch { /* The startup deadline remains authoritative. */ }
          }, 5_000)
        }),
      ])
      assertQueryTimeouts(rows)
      await healthClient`select 1`
    } catch {
      await close()
      // Driver errors can include connection metadata; emit a stable safe error.
      throw new Error("PgBouncer startup qualification failed; verify role timeout defaults and the direct health endpoint.")
    } finally {
      clearTimeout(timer)
    }
  }
  return { queryClient, healthClient, validateStartup, checkHealth, close }
}
