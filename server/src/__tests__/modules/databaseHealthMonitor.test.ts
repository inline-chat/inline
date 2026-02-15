import { DatabaseHealthMonitor } from "@in/server/modules/monitoring/databaseHealthMonitor"
import { describe, expect, it } from "bun:test"

type HealthSample = {
  ok: boolean
  checks: {
    database: {
      ok: boolean
      latencyMs: number
      error?: "database_unavailable"
    }
  }
}

const healthySample = (): HealthSample => ({
  ok: true,
  checks: {
    database: {
      ok: true,
      latencyMs: 3,
    },
  },
})

const downSample = (): HealthSample => ({
  ok: false,
  checks: {
    database: {
      ok: false,
      latencyMs: 3,
      error: "database_unavailable",
    },
  },
})

describe("DatabaseHealthMonitor", () => {
  it("alerts only after reaching failure threshold", async () => {
    const alerts: string[] = []
    const samples = [downSample(), downSample()]

    const monitor = new DatabaseHealthMonitor({
      failureThreshold: 2,
      healthRunner: async () => samples.shift() ?? downSample(),
      alertSender: (message) => alerts.push(message),
    })

    await monitor.pollOnce()
    expect(alerts.length).toBe(0)

    await monitor.pollOnce()
    expect(alerts.length).toBe(1)
    expect(alerts[0]).toContain("DB DOWN")
  })

  it("sends repeated still-down alerts only after cooldown", async () => {
    const alerts: string[] = []
    let now = 1_000

    const monitor = new DatabaseHealthMonitor({
      failureThreshold: 1,
      alertCooldownMs: 60_000,
      now: () => now,
      healthRunner: async () => downSample(),
      alertSender: (message) => alerts.push(message),
    })

    await monitor.pollOnce()
    expect(alerts.length).toBe(1)

    now += 30_000
    await monitor.pollOnce()
    expect(alerts.length).toBe(1)

    now += 31_000
    await monitor.pollOnce()
    expect(alerts.length).toBe(2)
    expect(alerts[1]).toContain("STILL DOWN")
  })

  it("sends a recovery alert after database becomes healthy", async () => {
    const alerts: string[] = []
    const samples = [downSample(), healthySample()]
    let now = 10_000

    const monitor = new DatabaseHealthMonitor({
      failureThreshold: 1,
      now: () => now,
      healthRunner: async () => samples.shift() ?? healthySample(),
      alertSender: (message) => alerts.push(message),
    })

    await monitor.pollOnce()
    expect(alerts.length).toBe(1)
    expect(alerts[0]).toContain("DB DOWN")

    now += 25_000
    await monitor.pollOnce()
    expect(alerts.length).toBe(2)
    expect(alerts[1]).toContain("DB RECOVERED")
  })

  it("treats health-runner exceptions as downtime", async () => {
    const alerts: string[] = []

    const monitor = new DatabaseHealthMonitor({
      failureThreshold: 1,
      healthRunner: async () => {
        throw new Error("unexpected")
      },
      alertSender: (message) => alerts.push(message),
    })

    await monitor.pollOnce()
    expect(alerts.length).toBe(1)
    expect(alerts[0]).toContain("DB DOWN")
  })
})
