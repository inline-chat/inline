import { db } from "@in/server/db"
import { getServerShutdownState, type ShutdownSignal } from "@in/server/lifecycle/shutdownState"
import { setup } from "@in/server/setup"
import { sql } from "drizzle-orm"
import { Elysia } from "elysia"

type DbExecutor = Pick<typeof db, "execute">

export type HealthDeps = {
  db: DbExecutor
}

export type HealthLifecycleDeps = {
  getShutdownState?: typeof getServerShutdownState
}

export type HealthResponse = {
  ok: boolean
  status: "ok" | "degraded"
  timestamp: number
  checks: {
    database: {
      ok: boolean
      latencyMs: number
      error?: "database_unavailable"
    }
  }
}

export type HealthHttpResponse = HealthResponse & {
  draining: boolean
  checks: HealthResponse["checks"] & {
    lifecycle: {
      ok: boolean
      error?: "shutting_down"
      signal?: ShutdownSignal
    }
  }
}

const checkDatabase = async (executor: DbExecutor): Promise<HealthResponse["checks"]["database"]> => {
  const startedAt = performance.now()
  try {
    await executor.execute(sql`SELECT 1`)
    return {
      ok: true,
      latencyMs: Math.round(performance.now() - startedAt),
    }
  } catch {
    return {
      ok: false,
      latencyMs: Math.round(performance.now() - startedAt),
      error: "database_unavailable",
    }
  }
}

const resolveHealthDeps = (deps?: HealthDeps): HealthDeps => deps ?? { db }

export const runHealthChecks = async (deps?: HealthDeps): Promise<HealthResponse> => {
  const database = await checkDatabase(resolveHealthDeps(deps).db)
  const ok = database.ok

  return {
    ok,
    status: ok ? "ok" : "degraded",
    timestamp: Math.floor(Date.now() / 1000),
    checks: {
      database,
    },
  }
}

const withLifecycleCheck = (result: HealthResponse, deps?: HealthLifecycleDeps): HealthHttpResponse => {
  const shutdownState = deps?.getShutdownState?.() ?? getServerShutdownState()

  if (!shutdownState.shuttingDown) {
    return {
      ...result,
      draining: false,
      checks: {
        ...result.checks,
        lifecycle: {
          ok: true,
        },
      },
    }
  }

  return {
    ...result,
    ok: false,
    status: "degraded",
    draining: true,
    checks: {
      ...result.checks,
      lifecycle: {
        ok: false,
        error: "shutting_down",
        signal: shutdownState.signal ?? undefined,
      },
    },
  }
}

export const createHealthController = (deps?: HealthDeps, lifecycleDeps?: HealthLifecycleDeps) => {
  const healthHandler = async ({ set }: { set: { status?: number | string } }) => {
    const result = withLifecycleCheck(await runHealthChecks(resolveHealthDeps(deps)), lifecycleDeps)
    set.status = result.ok ? 200 : 503
    return result
  }

  return new Elysia({ name: "health" })
    .use(setup)
    .get("/healthz", healthHandler)
    .get("/health", healthHandler)
}

export const health = createHealthController()
