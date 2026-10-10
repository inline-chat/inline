import { DatabaseHealthMonitor } from "@in/server/modules/monitoring/databaseHealthMonitor"
import type { InlineProtocolClockHealth } from "@in/server/modules/inlineProtocol/clockHealth"
import { describe, expect, it, spyOn } from "bun:test"

type HealthSample = {
  ok: boolean
  checks: {
    database: {
      ok: boolean
      latencyMs: number
      error?: "database_unavailable"
    }
    clock?: InlineProtocolClockHealth
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
      alertSender: (message) => { alerts.push(message) },
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
      alertSender: (message) => { alerts.push(message) },
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
      alertSender: (message) => { alerts.push(message) },
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
      alertSender: (message) => { alerts.push(message) },
    })

    await monitor.pollOnce()
    expect(alerts.length).toBe(1)
    expect(alerts[0]).toContain("DB DOWN")
  })

  it("retries a failed down alert on the next poll and starts cooldown only after delivery", async () => {
    const attempts: string[] = []
    let now = 1_000
    const monitor = new DatabaseHealthMonitor({
      failureThreshold: 1, alertCooldownMs: 60_000, now: () => now,
      healthRunner: async () => downSample(),
      alertSender: async (message) => {
        attempts.push(message)
        if (attempts.length === 1) throw new Error("synthetic-provider-failure")
      },
    })
    await monitor.pollOnce()
    now += 1_000
    await monitor.pollOnce()
    expect(attempts).toHaveLength(2)
    expect(attempts.every((message) => message.includes("DB DOWN"))).toBe(true)
    now += 59_000
    await monitor.pollOnce()
    expect(attempts).toHaveLength(2)
    now += 1_000
    await monitor.pollOnce()
    expect(attempts).toHaveLength(3)
    expect(attempts[2]).toContain("DB STILL DOWN")
  })

  it("retries a failed still-down reminder without waiting another cooldown", async () => {
    const attempts: string[] = []
    let now = 1_000
    const monitor = new DatabaseHealthMonitor({
      failureThreshold: 1, alertCooldownMs: 60_000, now: () => now,
      healthRunner: async () => downSample(),
      alertSender: async (message) => {
        attempts.push(message)
        if (attempts.length === 2) throw new Error("synthetic-provider-failure")
      },
    })
    await monitor.pollOnce()
    now += 60_000
    await monitor.pollOnce()
    now += 1_000
    await monitor.pollOnce()
    expect(attempts).toHaveLength(3)
    expect(attempts.slice(1).every((message) => message.includes("DB STILL DOWN"))).toBe(true)
  })

  it("retains failed recovery delivery across healthy polls with the original downtime", async () => {
    const samples = [downSample(), healthySample(), healthySample(), healthySample()]
    const attempts: string[] = []
    let now = 1_000
    const monitor = new DatabaseHealthMonitor({
      failureThreshold: 1, now: () => now,
      healthRunner: async () => samples.shift() ?? healthySample(),
      alertSender: async (message) => {
        attempts.push(message)
        if (attempts.length === 2) throw new Error("synthetic-provider-failure")
      },
    })
    await monitor.pollOnce()
    now += 25_000
    await monitor.pollOnce()
    now += 30_000
    await monitor.pollOnce()
    await monitor.pollOnce()
    expect(attempts).toHaveLength(3)
    expect(attempts[1]).toContain("DB RECOVERED")
    expect(attempts[1]).toContain("after 25s")
    expect(attempts[2]).toBe(attempts[1])
  })

  it("coalesces repeated recoveries during unavailable delivery before a later outage alert", async () => {
    const samples = [downSample(), healthySample(), downSample(), healthySample(), downSample()]
    const delivered: string[] = []
    let available = false
    const monitor = new DatabaseHealthMonitor({
      failureThreshold: 1,
      healthRunner: async () => samples.shift() ?? downSample(),
      alertSender: async (message) => {
        if (!available) throw new Error("synthetic-provider-failure")
        delivered.push(message)
      },
    })
    for (let index = 0; index < 4; index += 1) await monitor.pollOnce()
    available = true
    await monitor.pollOnce()
    expect(delivered).toHaveLength(2)
    expect(delivered[0]).toContain("DB RECOVERED")
    expect(delivered[0]).toContain("2 recoveries observed")
    expect(delivered[1]).toContain("DB DOWN")
  })

  it("awaits delivery and prevents overlapping polls while the send is pending", async () => {
    let release: (() => void) | undefined
    let reads = 0
    const monitor = new DatabaseHealthMonitor({
      failureThreshold: 1,
      healthRunner: async () => { reads += 1; return downSample() },
      alertSender: () => new Promise<void>((resolve) => { release = resolve }),
    })
    const poll = monitor.pollOnce()
    try {
      // Advance the resolved health read to the awaited sender without timers.
      for (let index = 0; index < 5; index += 1) await Promise.resolve()
      expect(release).toBeDefined()
      await monitor.pollOnce()
      expect(reads).toBe(1)
    } finally {
      release?.()
      await poll
    }
  })

  it("the default sender calls Telegram directly with no Inline fallback", async () => {
    const oldToken = process.env["TELEGRAM_ALERTS_BOT_TOKEN"]
    const oldChatId = process.env["TELEGRAM_ALERTS_CHAT_ID"]
    process.env["TELEGRAM_ALERTS_BOT_TOKEN"] = "synthetic-default"
    process.env["TELEGRAM_ALERTS_CHAT_ID"] = "123"
    const request = spyOn(globalThis, "fetch").mockResolvedValue(Response.json({ ok: false }))
    try {
      const monitor = new DatabaseHealthMonitor({ failureThreshold: 1, healthRunner: async () => downSample() })
      await monitor.pollOnce()
      await monitor.pollOnce()
      expect(request).toHaveBeenCalledTimes(2)
      expect(request.mock.calls.every(([url]) => url === "https://api.telegram.org/botsynthetic-default/sendMessage")).toBe(true)
    } finally {
      request.mockRestore()
      if (oldToken === undefined) delete process.env["TELEGRAM_ALERTS_BOT_TOKEN"]
      else process.env["TELEGRAM_ALERTS_BOT_TOKEN"] = oldToken
      if (oldChatId === undefined) delete process.env["TELEGRAM_ALERTS_CHAT_ID"]
      else process.env["TELEGRAM_ALERTS_CHAT_ID"] = oldChatId
    }
  })

  it("clock warnings retry failed delivery and retain their independent cooldown", async () => {
    let now = 1_000
    const attempts: string[] = []
    const monitor = new DatabaseHealthMonitor({
      alertCooldownMs: 60_000, now: () => now,
      healthRunner: async () => ({
        ...healthySample(),
        checks: {
          ...healthySample().checks,
          clock: { ok: true, status: "warning", offsetMillis: 6_000, stepMillis: 0, warning: "clock_offset_warning" },
        },
      }),
      alertSender: async (message) => {
        attempts.push(message)
        if (attempts.length === 1) throw new Error("synthetic-provider-failure")
      },
    })
    await monitor.pollOnce()
    now += 1_000
    await monitor.pollOnce()
    expect(attempts).toHaveLength(2)
    expect(attempts.every((message) => message.includes("CLOCK WARNING"))).toBe(true)
    now += 59_000
    await monitor.pollOnce()
    expect(attempts).toHaveLength(2)
    now += 1_000
    await monitor.pollOnce()
    expect(attempts).toHaveLength(3)
  })

  it("clock safety failures keep their own unsafe and recovery wording", async () => {
    const unsafe: HealthSample = {
      ok: false,
      checks: {
        database: healthySample().checks.database,
        clock: { ok: false, status: "degraded", offsetMillis: 25_000, stepMillis: 0, error: "clock_offset_exceeded" },
      },
    }
    const samples = [unsafe, healthySample()]
    const delivered: string[] = []
    const monitor = new DatabaseHealthMonitor({
      failureThreshold: 1,
      healthRunner: async () => samples.shift() ?? healthySample(),
      alertSender: async (message) => { delivered.push(message) },
    })
    await monitor.pollOnce()
    await monitor.pollOnce()
    expect(delivered).toHaveLength(2)
    expect(delivered[0]).toContain("CLOCK UNSAFE")
    expect(delivered[1]).toContain("CLOCK RECOVERED")
    expect(delivered.every((message) => !message.includes("DB DOWN"))).toBe(true)
  })

  it("does not alert from a health read that completes after the monitor stops", async () => {
    let release: ((sample: HealthSample) => void) | undefined
    let readFinished: (() => void) | undefined
    const finished = new Promise<void>((resolve) => { readFinished = resolve })
    const delivered: string[] = []
    const monitor = new DatabaseHealthMonitor({
      failureThreshold: 1,
      healthRunner: async () => {
        const sample = await new Promise<HealthSample>((resolve) => { release = resolve })
        readFinished?.()
        return sample
      },
      alertSender: async (message) => { delivered.push(message) },
    })
    monitor.start()
    try {
      expect(release).toBeDefined()
      monitor.stop()
      release?.(downSample())
      await finished
      // Drain continuations from the stopped fire-and-forget startup poll.
      for (let index = 0; index < 5; index += 1) await Promise.resolve()
      expect(delivered).toEqual([])
    } finally {
      monitor.stop()
      release?.(healthySample())
      await finished
    }
  })
})
