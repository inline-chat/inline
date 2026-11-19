import { setupTestLifecycle } from "@in/server/__tests__/setup"
import {
  makeHealthChecker,
  runHealthChecks,
  runLivenessCheck,
  withLifecycleCheck,
  type LivenessHttpResponse,
  type HealthDeps,
  type HealthHttpResponse,
  type HealthLifecycleDeps,
} from "@in/server/controllers/healthCheck"
import {
  executeLiveness,
  executeReadiness,
  HealthOperations,
  makeHealthOperations,
} from "@in/server/controllers/health.effect"
import { markServerShuttingDown, resetServerShutdownStateForTests } from "@in/server/lifecycle/shutdownState"
import { describe, expect, it } from "bun:test"
import { Effect } from "effect"
import { HttpServerResponse } from "effect/unstable/http"
import { useLiveHttpApp } from "./liveHttpApp"

const app = useLiveHttpApp()

/**
 * The Effect health routes over injected checks, composed like
 * `HealthOperationsLive` but with test dependencies.
 */
const isolatedHealth = (deps?: Partial<HealthDeps>, lifecycleDeps?: HealthLifecycleDeps) => {
  const checkHealth = makeHealthChecker(deps)
  const operations = makeHealthOperations(
    async () => withLifecycleCheck(await checkHealth(), lifecycleDeps),
    async () => runLivenessCheck(lifecycleDeps),
  )
  const respond = (execute: typeof executeLiveness) =>
    Effect.runPromise(execute.pipe(Effect.provideService(HealthOperations, operations)))
      .then((response) => HttpServerResponse.toWeb(response))
  return { liveness: () => respond(executeLiveness), readiness: () => respond(executeReadiness) }
}

setupTestLifecycle()

const failingHealthDeps = (): HealthDeps => ({
  checkDatabase: () => Promise.reject(new Error("db down")),
})

describe("health endpoints", () => {
  it("returns process liveness on /healthz", async () => {
    const response = await app.handle(new Request("http://localhost/healthz"))
    expect(response.status).toBe(200)

    const json = (await response.json()) as LivenessHttpResponse
    expect(json.ok).toBe(true)
    expect(json.status).toBe("ok")
    expect(json.checks.lifecycle.ok).toBe(true)
  })

  it("provides /health alias with the same process liveness check", async () => {
    const response = await app.handle(new Request("http://localhost/health"))
    expect(response.status).toBe(200)

    const json = (await response.json()) as LivenessHttpResponse
    expect(json.ok).toBe(true)
    expect(json.status).toBe("ok")
    expect(json.checks.lifecycle.ok).toBe(true)
  })

  it("provides database-backed readiness on /readyz", async () => {
    const response = await app.handle(new Request("http://localhost/readyz"))
    expect(response.status).toBe(200)

    const json = (await response.json()) as HealthHttpResponse
    expect(json.ok).toBe(true)
    expect(json.checks.database.ok).toBe(true)
    expect(typeof json.checks.database.latencyMs).toBe("number")
  })

  it("provides process liveness without waiting for the database", async () => {
    const stalledHealth = isolatedHealth({
      checkDatabase: () => new Promise(() => {}),
      timeoutMs: 10,
    })

    const response = await stalledHealth.liveness()
    expect(response.status).toBe(200)

    const json = (await response.json()) as LivenessHttpResponse
    expect(json.ok).toBe(true)
    expect(json.draining).toBe(false)
    expect(json.checks.lifecycle.ok).toBe(true)
  })

  it("bounds and cancels stalled database readiness checks", async () => {
    let cancelled = false
    const stalled = new Promise<void>(() => {}) as Promise<void> & {
      cancel: () => void
    }
    stalled.cancel = () => {
      cancelled = true
    }

    const startedAt = performance.now()
    const degraded = await runHealthChecks({
      checkDatabase: () => stalled,
      timeoutMs: 10,
    })

    expect(performance.now() - startedAt).toBeLessThan(250)
    expect(degraded.ok).toBe(false)
    expect(cancelled).toBe(true)
  })

  it("marks health as degraded when database checks fail", async () => {
    const degraded = await runHealthChecks(failingHealthDeps())

    expect(degraded.ok).toBe(false)
    expect(degraded.status).toBe("degraded")
    expect(degraded.checks.database.ok).toBe(false)
    expect(degraded.checks.database.error).toBe("database_unavailable")
  })

  it("returns HTTP 503 from /readyz when database checks fail", async () => {
    const failingHealth = isolatedHealth(failingHealthDeps())

    const response = await failingHealth.readiness()
    expect(response.status).toBe(503)

    const json = (await response.json()) as Awaited<ReturnType<typeof runHealthChecks>>
    expect(json.ok).toBe(false)
    expect(json.status).toBe("degraded")
    expect(json.checks.database.error).toBe("database_unavailable")
  })

  it("returns HTTP 503 and lifecycle draining check when server is shutting down", async () => {
    markServerShuttingDown("SIGTERM")
    try {
      const responseDuringShutdown = await app.handle(new Request("http://localhost/healthz"))
      expect(responseDuringShutdown.status).toBe(503)

      const during = (await responseDuringShutdown.json()) as LivenessHttpResponse
      expect(during.ok).toBe(false)
      expect(during.status).toBe("degraded")
      expect(during.draining).toBe(true)
      expect(during.checks.lifecycle.ok).toBe(false)
      expect(during.checks.lifecycle.error).toBe("shutting_down")
      expect(during.checks.lifecycle.signal).toBe("SIGTERM")

      const livenessDuringShutdown = await app.handle(
        new Request("http://localhost/livez"),
      )
      expect(livenessDuringShutdown.status).toBe(503)
      expect(await livenessDuringShutdown.json()).toMatchObject({
        ok: false,
        draining: true,
        checks: {
          lifecycle: {
            error: "shutting_down",
            signal: "SIGTERM",
          },
        },
      })
    } finally {
      resetServerShutdownStateForTests()
    }
  })
})
