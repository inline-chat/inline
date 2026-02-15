import { setupTestLifecycle } from "@in/server/__tests__/setup"
import {
  createHealthController,
  runHealthChecks,
  type HealthDeps,
  type HealthHttpResponse,
} from "@in/server/controllers/health"
import { app } from "@in/server/index"
import { describe, expect, it } from "bun:test"
import Elysia from "elysia"

setupTestLifecycle()

const failingHealthDeps = (): HealthDeps => ({
  db: {
    execute: ((_) => {
      throw new Error("db down")
    }) as HealthDeps["db"]["execute"],
  },
})

describe("health endpoints", () => {
  it("returns healthy status on /healthz when database is reachable", async () => {
    const response = await app.handle(new Request("http://localhost/healthz"))
    expect(response.status).toBe(200)

    const json = (await response.json()) as Awaited<ReturnType<typeof runHealthChecks>>
    expect(json.ok).toBe(true)
    expect(json.status).toBe("ok")
    expect(json.checks.database.ok).toBe(true)
    expect(typeof json.checks.database.latencyMs).toBe("number")
  })

  it("provides /health alias with same readiness checks", async () => {
    const response = await app.handle(new Request("http://localhost/health"))
    expect(response.status).toBe(200)

    const json = (await response.json()) as Awaited<ReturnType<typeof runHealthChecks>>
    expect(json.ok).toBe(true)
    expect(json.status).toBe("ok")
    expect(json.checks.database.ok).toBe(true)
  })

  it("marks health as degraded when database checks fail", async () => {
    const degraded = await runHealthChecks(failingHealthDeps())

    expect(degraded.ok).toBe(false)
    expect(degraded.status).toBe("degraded")
    expect(degraded.checks.database.ok).toBe(false)
    expect(degraded.checks.database.error).toBe("database_unavailable")
  })

  it("returns HTTP 503 from /healthz when database checks fail", async () => {
    const failingHealth = createHealthController(failingHealthDeps())

    const isolated = new Elysia().use(failingHealth)
    const response = await isolated.handle(new Request("http://localhost/healthz"))
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

    const during = (await responseDuringShutdown.json()) as HealthHttpResponse
    expect(during.ok).toBe(false)
    expect(during.status).toBe("degraded")
    expect(during.draining).toBe(true)
    expect(during.checks.lifecycle.ok).toBe(false)
    expect(during.checks.lifecycle.error).toBe("shutting_down")
    expect(during.checks.lifecycle.signal).toBe("SIGTERM")
  })
})
