import postgres from "postgres"
import { prepareQueries, type PreparedQueryPolicy } from "./preparedQueries"

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
  INLINE_DATABASE_QUERY_POOL_MAX?: string
  INLINE_DATABASE_PREPARED_QUERIES?: string
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

type CancellableHealthProbe<T = unknown> = PromiseLike<T> & { readonly cancel?: () => void }

/** The migration head only moves on deploy or restore. */
export const HEALTH_VALIDATION_INTERVAL_MS = 60_000

/**
 * Runs a validation probe at most once per interval after it last passed.
 * The first probe after startup always runs, a rejected probe is never
 * cached, so readiness keeps re-checking (and failing) until a fresh check
 * passes, and a restored older database is caught within one interval.
 */
export const cachedHealthProbe = (
  run: () => CancellableHealthProbe<void>,
  options: { intervalMs?: number; now?: () => number } = {},
): (() => CancellableHealthProbe<void> | undefined) => {
  const intervalMs = options.intervalMs ?? HEALTH_VALIDATION_INTERVAL_MS
  const now = options.now ?? Date.now
  let passedAtMs: number | undefined
  return () => {
    const startedAtMs = now()
    if (passedAtMs !== undefined && startedAtMs - passedAtMs < intervalMs) return undefined
    const probe = run()
    return Object.assign(
      Promise.resolve(probe).then(() => {
        // Record the start, not the completion, so a slow probe cannot
        // extend the window past one interval of real time.
        if (passedAtMs === undefined || startedAtMs > passedAtMs) passedAtMs = startedAtMs
      }),
      { cancel: () => probe.cancel?.() },
    )
  }
}

/** Never release readiness admission while a child probe is still queued/running. */
export const combineHealthProbes = <T>(
  primary: CancellableHealthProbe<T>,
  additional: readonly CancellableHealthProbe[],
) => {
  const probes = [primary, ...additional]
  return Object.assign(Promise.allSettled(probes).then((results) => {
    for (const result of results) {
      if (result.status === "rejected") throw result.reason
    }
    return primary
  }), {
    cancel: () => {
      let failed = false
      let failure: unknown
      for (const probe of probes) {
        try { probe.cancel?.() } catch (error) {
          if (!failed) failure = error
          failed = true
        }
      }
      if (failed) throw failure
    },
  })
}

/**
 * Names connections per origin so Insights can attribute load to each server.
 * An explicit INLINE_NODE_NAME wins and Fly Machines report their region;
 * without either the historical unsuffixed name is kept.
 */
export const databaseApplicationName = (base: "inline-server" | "inline-health", environment: DatabaseEnvironment): string => {
  const flyRegion = environment["FLY_REGION"]?.trim()
  const node = environment["INLINE_NODE_NAME"]?.trim() || (flyRegion ? `fly-${flyRegion}` : "")
  const safe = node.replace(/[^A-Za-z0-9._-]/g, "").slice(0, 32)
  return safe ? `${base}:${safe}` : base
}

export const makeDatabaseClients = (databaseUrl: string, environment: DatabaseEnvironment = {}) => {
  const queryPoolMax = environment.INLINE_DATABASE_QUERY_POOL_MAX ?? "10"
  if (!/^(?:[1-9]|10)$/.test(queryPoolMax) || queryPoolMax.trim() !== queryPoolMax) {
    throw new Error("INLINE_DATABASE_QUERY_POOL_MAX must be an integer from 1 through 10.")
  }
  const preparedMode = environment.INLINE_DATABASE_PREPARED_QUERIES ?? "access"
  if (preparedMode !== "access" && preparedMode !== "all-custom") {
    throw new Error("INLINE_DATABASE_PREPARED_QUERIES must be access or all-custom.")
  }
  const preparation: PreparedQueryPolicy = { mode: "access" }
  const policy = databaseConnectionPolicy(databaseUrl, environment)
  const queryClient = postgres(policy.queryUrl, {
    max: Number(queryPoolMax), connect_timeout: 5, idle_timeout: 30,
    connection: {
      application_name: databaseApplicationName("inline-server", environment),
      ...(policy.mode === "direct" ? QUERY_TIMEOUTS : {}),
    },
  })
  const healthClient = postgres(policy.healthUrl, {
    max: 1, connect_timeout: 2, idle_timeout: 30,
    connection: { application_name: databaseApplicationName("inline-health", environment), ...HEALTH_TIMEOUTS },
  })
  prepareQueries(queryClient, preparation)
  const close = () => Promise.all([queryClient.end({ timeout: 5 }), healthClient.end({ timeout: 5 })]).then(() => {})
  // Readiness runs this through the pool on every probe, so it must stay
  // cheap: current_setting() reads four GUCs directly, whereas the pg_settings
  // view materializes every setting first (about 1.2 ms per probe in
  // production, 8% of all measured query time). Timeouts are normalized to
  // the millisecond shape pg_settings reports so assertQueryTimeouts is unchanged.
  const queryTimeoutSettings = () => queryClient<TimeoutRow[]>`
    select name, setting, unit from (values
      ('statement_timeout', (extract(epoch from current_setting('statement_timeout')::interval) * 1000)::bigint::text, 'ms'),
      ('lock_timeout', (extract(epoch from current_setting('lock_timeout')::interval) * 1000)::bigint::text, 'ms'),
      ('idle_in_transaction_session_timeout', (extract(epoch from current_setting('idle_in_transaction_session_timeout')::interval) * 1000)::bigint::text, 'ms'),
      ('plan_cache_mode', current_setting('plan_cache_mode'), null::text)
    ) as settings(name, setting, unit)
  `.execute()
  const assertPreparation = (rows: readonly TimeoutRow[]) => {
    if (preparedMode === "all-custom" && rows.find((row) => row.name === "plan_cache_mode")?.setting !== "force_custom_plan") {
      preparation.mode = "access"
      throw new Error("all-custom preparation requires force_custom_plan on the query role.")
    }
  }
  const checkHealth = () => {
    const direct = healthClient.unsafe(
      "SELECT (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::double precision AS database_time_millis",
    ).execute()
    if (policy.mode === "direct" && preparedMode !== "all-custom") return direct
    // A healthy direct endpoint must not hide a broken/queued pooled endpoint,
    // and a role that lost its timeout or plan-cache qualification must fail
    // readiness on the next probe, not a minute later. So the pooled read is
    // never cached; it is kept cheap instead. The health controller's existing
    // deadline cancels both pending queries.
    const pooled = queryTimeoutSettings()
    const probes = combineHealthProbes(direct, [pooled])
    return Object.assign(probes.then(async (clock) => {
      const rows = await pooled
      if (policy.mode === "pgbouncer") assertQueryTimeouts(rows)
      assertPreparation(rows)
      return clock
    }), { cancel: probes.cancel })
  }
  const validateStartup = async (): Promise<void> => {
    if (policy.mode === "direct" && preparedMode === "access") return
    const query = queryTimeoutSettings()
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      const rows = await Promise.race([
        query,
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => {
            reject(new Error("Database role qualification exceeded 5 seconds."))
            try { query.cancel() } catch { /* The startup deadline remains authoritative. */ }
          }, 5_000)
        }),
      ])
      if (policy.mode === "pgbouncer") assertQueryTimeouts(rows)
      // The query path can use a different role from the direct health client.
      // Operators must also recycle existing backends after setting role defaults.
      assertPreparation(rows)
      if (policy.mode === "pgbouncer") await healthClient`select 1`
      preparation.mode = preparedMode
    } catch {
      await close()
      // Driver errors can include connection metadata; emit a stable safe error.
      throw new Error(`${policy.mode === "pgbouncer" ? "PgBouncer" : "Database"} startup qualification failed; verify role timeout defaults, the direct health endpoint, and force_custom_plan when all-custom preparation is enabled.`)
    } finally {
      clearTimeout(timer)
    }
  }
  const diagnosticsConfiguration = {
    mode: policy.mode,
    preparedQueries: preparedMode,
    queryPoolMax: queryClient.options.max,
    healthPoolMax: healthClient.options.max,
    statementTimeoutMs: QUERY_TIMEOUTS.statement_timeout,
    lockTimeoutMs: QUERY_TIMEOUTS.lock_timeout,
    idleTransactionTimeoutMs: QUERY_TIMEOUTS.idle_in_transaction_session_timeout,
  }
  return { queryClient, healthClient, validateStartup, checkHealth, close, diagnosticsConfiguration }
}
