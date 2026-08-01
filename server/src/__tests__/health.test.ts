import { setupTestLifecycle } from "@in/server/__tests__/setup"
import {
  createHealthController,
  runHealthChecks,
  type LivenessHttpResponse,
  type HealthDeps,
  type HealthHttpResponse,
} from "@in/server/controllers/health"
import { app } from "@in/server/legacyServer"
import { describe, expect, it } from "bun:test"
import Elysia from "elysia"

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
    const stalledHealth = createHealthController({
      checkDatabase: () => new Promise(() => {}),
      timeoutMs: 10,
    })
    const isolated = new Elysia().use(stalledHealth)

    const response = await isolated.handle(new Request("http://localhost/healthz"))
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
    const failingHealth = createHealthController(failingHealthDeps())

    const isolated = new Elysia().use(failingHealth)
    const response = await isolated.handle(new Request("http://localhost/readyz"))
    expect(response.status).toBe(503)

    const json = (await response.json()) as Awaited<ReturnType<typeof runHealthChecks>>
    expect(json.ok).toBe(false)
    expect(json.status).toBe("degraded")
    expect(json.checks.database.error).toBe("database_unavailable")
  })

  it("returns HTTP 503 and lifecycle draining check when server is shutting down", async () => {
    const drainingHealth = createHealthController(undefined, {
      getShutdownState: () => ({
        shuttingDown: true,
        signal: "SIGTERM",
        startedAtMs: Date.now(),
      }),
    })

    const isolated = new Elysia().use(drainingHealth)
    const responseDuringShutdown = await isolated.handle(new Request("http://localhost/healthz"))
    expect(responseDuringShutdown.status).toBe(503)

    const during = (await responseDuringShutdown.json()) as LivenessHttpResponse
    expect(during.ok).toBe(false)
    expect(during.status).toBe("degraded")
    expect(during.draining).toBe(true)
    expect(during.checks.lifecycle.ok).toBe(false)
    expect(during.checks.lifecycle.error).toBe("shutting_down")
    expect(during.checks.lifecycle.signal).toBe("SIGTERM")

    const livenessDuringShutdown = await isolated.handle(
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
  })
})
