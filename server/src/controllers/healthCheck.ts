import {
  checkDatabaseHealth,
} from "@in/server/db"
import {
  getServerShutdownState,
  type ShutdownSignal,
} from "@in/server/lifecycle/shutdownState"
import {
  inlineProtocolClock,
  type InlineProtocolClock,
  type InlineProtocolClockHealth,
} from "@in/server/modules/inlineProtocol/clockHealth"

const DEFAULT_DATABASE_HEALTH_TIMEOUT_MS = 2_000

interface CancellableHealthCheck
  extends PromiseLike<unknown> {
  readonly cancel?: () => void
}

export interface HealthDeps {
  readonly checkDatabase: () =>
    CancellableHealthCheck
  readonly clock?: Pick<InlineProtocolClock, "sample">
  readonly brokerRequired?: boolean
  readonly checkBroker?: () => boolean
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
    readonly clock: InlineProtocolClockHealth
    readonly broker?: {
      readonly ok: boolean
      readonly error?: "broker_unavailable"
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
  clock: inlineProtocolClock,
}

const runBoundedDatabaseCheck = async (
  deps: HealthDeps,
): Promise<unknown> => {
  const query = deps.checkDatabase()
  const timeoutMs =
    deps.timeoutMs ??
    DEFAULT_DATABASE_HEALTH_TIMEOUT_MS
  let timeoutId:
    | ReturnType<typeof setTimeout>
    | undefined

  try {
    return await new Promise<unknown>((resolve, reject) => {
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

      void Promise.resolve(query).then(resolve, reject)
    })
  } finally {
    if (timeoutId !== undefined) {
      clearTimeout(timeoutId)
    }
  }
}

const checkDatabase = async (
  deps: HealthDeps,
): Promise<{
  readonly health: HealthResponse["checks"]["database"]
  readonly referenceTimeMillis?: number
}> => {
  const startedAt = performance.now()
  try {
    const result = await runBoundedDatabaseCheck(deps)
    const latencyMs = performance.now() - startedAt
    const row = Array.isArray(result) ? result[0] : undefined
    const rawDatabaseTime = row && typeof row === "object"
      ? (row as Record<string, unknown>)["database_time_millis"]
      : undefined
    const databaseTimeMillis = typeof rawDatabaseTime === "number"
      ? rawDatabaseTime
      : typeof rawDatabaseTime === "string"
        ? Number(rawDatabaseTime)
        : undefined
    return {
      health: {
        ok: true,
        latencyMs: Math.round(latencyMs),
      },
      ...(databaseTimeMillis !== undefined && Number.isFinite(databaseTimeMillis)
        ? { referenceTimeMillis: databaseTimeMillis + latencyMs / 2 }
        : {}),
    }
  } catch {
    return {
      health: {
        ok: false,
        latencyMs: Math.round(performance.now() - startedAt),
        error: "database_unavailable",
      },
    }
  }
}

const resolveHealthDeps = (
  deps?: Partial<HealthDeps>,
): HealthDeps => ({
  ...defaultHealthDeps,
  ...deps,
})

export const runHealthChecks = async (
  deps?: Partial<HealthDeps>,
): Promise<HealthResponse> => {
  const resolved = resolveHealthDeps(deps)
  const databaseResult = await checkDatabase(resolved)
  const database = databaseResult.health
  const clock = (resolved.clock ?? inlineProtocolClock).sample(
    databaseResult.referenceTimeMillis,
  )
  const broker = resolved.brokerRequired
    ? (() => {
      const ok = resolved.checkBroker?.() === true
      return ok
        ? { ok }
        : { ok, error: "broker_unavailable" as const }
    })()
    : undefined
  const ok = database.ok && clock.ok && (broker?.ok ?? true)

  return {
    ok,
    status: ok ? "ok" : "degraded",
    timestamp: Math.floor(Date.now() / 1000),
    checks: {
      database,
      clock,
      ...(broker === undefined ? {} : { broker }),
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
