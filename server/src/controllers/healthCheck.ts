import { db } from "@in/server/db"
import {
  getServerShutdownState,
  type ShutdownSignal,
} from "@in/server/lifecycle/shutdownState"
import { sql } from "drizzle-orm"

type DbExecutor = Pick<typeof db, "execute">

export interface HealthDeps {
  readonly db: DbExecutor
}

export interface HealthLifecycleDeps {
  readonly getShutdownState?: typeof getServerShutdownState
}

export interface HealthResponse {
  readonly ok: boolean
  readonly status: "ok" | "degraded"
  readonly timestamp: number
  readonly checks: {
    readonly database: {
      readonly ok: boolean
      readonly latencyMs: number
      readonly error?: "database_unavailable"
    }
  }
}

export interface HealthHttpResponse extends HealthResponse {
  readonly draining: boolean
  readonly checks: HealthResponse["checks"] & {
    readonly lifecycle: {
      readonly ok: boolean
      readonly error?: "shutting_down"
      readonly signal?: ShutdownSignal
    }
  }
}

const checkDatabase = async (
  executor: DbExecutor,
): Promise<HealthResponse["checks"]["database"]> => {
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

const resolveHealthDeps = (
  deps?: HealthDeps,
): HealthDeps => deps ?? { db }

export const runHealthChecks = async (
  deps?: HealthDeps,
): Promise<HealthResponse> => {
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

export const withLifecycleCheck = (
  result: HealthResponse,
  deps?: HealthLifecycleDeps,
): HealthHttpResponse => {
  const shutdownState =
    deps?.getShutdownState?.() ?? getServerShutdownState()

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
