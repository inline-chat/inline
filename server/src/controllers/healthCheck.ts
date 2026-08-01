import {
  checkDatabaseHealth,
} from "@in/server/db"
import {
  getServerShutdownState,
  type ShutdownSignal,
} from "@in/server/lifecycle/shutdownState"

const DEFAULT_DATABASE_HEALTH_TIMEOUT_MS = 2_000

interface CancellableHealthCheck
  extends PromiseLike<unknown> {
  readonly cancel?: () => void
}

export interface HealthDeps {
  readonly checkDatabase: () =>
    CancellableHealthCheck
  readonly timeoutMs?: number
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

export interface LivenessHttpResponse {
  readonly ok: boolean
  readonly status: "ok" | "degraded"
  readonly timestamp: number
  readonly draining: boolean
  readonly checks: {
    readonly lifecycle: {
      readonly ok: boolean
      readonly error?: "shutting_down"
      readonly signal?: ShutdownSignal
    }
  }
}

const defaultHealthDeps: HealthDeps = {
  checkDatabase: checkDatabaseHealth,
}

const runBoundedDatabaseCheck = async (
  deps: HealthDeps,
): Promise<void> => {
  const query = deps.checkDatabase()
  const timeoutMs =
    deps.timeoutMs ??
    DEFAULT_DATABASE_HEALTH_TIMEOUT_MS
  let timeoutId:
    | ReturnType<typeof setTimeout>
    | undefined

  try {
    await new Promise<void>((resolve, reject) => {
      timeoutId = setTimeout(() => {
        reject(
          new Error(
            `Database health check exceeded ${timeoutMs}ms.`,
          ),
        )
        try {
          query.cancel?.()
        } catch {
          // The bounded readiness result is authoritative even if protocol-level cancellation fails.
        }
      }, timeoutMs)

      void Promise.resolve(query).then(
        () => resolve(),
        reject,
      )
    })
  } finally {
    if (timeoutId !== undefined) {
      clearTimeout(timeoutId)
    }
  }
}

const checkDatabase = async (
  deps: HealthDeps,
): Promise<HealthResponse["checks"]["database"]> => {
  const startedAt = performance.now()
  try {
    await runBoundedDatabaseCheck(deps)
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
): HealthDeps => deps ?? defaultHealthDeps

export const runHealthChecks = async (
  deps?: HealthDeps,
): Promise<HealthResponse> => {
  const database = await checkDatabase(
    resolveHealthDeps(deps),
  )
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

const lifecycleCheck = (
  deps?: HealthLifecycleDeps,
): LivenessHttpResponse => {
  const shutdownState =
    deps?.getShutdownState?.() ??
    getServerShutdownState()

  if (!shutdownState.shuttingDown) {
    return {
      ok: true,
      status: "ok",
      timestamp: Math.floor(Date.now() / 1000),
      draining: false,
      checks: {
        lifecycle: {
          ok: true,
        },
      },
    }
  }

  return {
    ok: false,
    status: "degraded",
    timestamp: Math.floor(Date.now() / 1000),
    draining: true,
    checks: {
      lifecycle: {
        ok: false,
        error: "shutting_down",
        signal:
          shutdownState.signal ?? undefined,
      },
    },
  }
}

export const runLivenessCheck = (
  deps?: HealthLifecycleDeps,
): LivenessHttpResponse => lifecycleCheck(deps)

export const withLifecycleCheck = (
  result: HealthResponse,
  deps?: HealthLifecycleDeps,
): HealthHttpResponse => {
  const liveness = lifecycleCheck(deps)

  if (liveness.ok) {
    return {
      ...result,
      draining: false,
      checks: {
        ...result.checks,
        lifecycle: liveness.checks.lifecycle,
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
        ...liveness.checks.lifecycle,
      },
    },
  }
}
