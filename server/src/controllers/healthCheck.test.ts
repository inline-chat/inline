import { describe, expect, it } from "bun:test"
import { InlineProtocolClock } from "@in/server/modules/inlineProtocol/clockHealth"
import { combineHealthProbes } from "@in/server/db/connectionPolicy"
import { makeHealthChecker, runHealthChecks, withLifecycleCheck } from "./healthCheck"

describe("runHealthChecks", () => {
  it("keeps readiness while reporting an unavailable optional broker", async () => {
    const result = await runHealthChecks({
      checkDatabase: async () => [{ database_time_millis: Date.now() }],
      checkBroker: () => false,
    })

    expect(result).toMatchObject({
      ok: true,
      status: "degraded",
      checks: {
        broker: {
          ok: false,
          error: "broker_unavailable",
        },
      },
    })
  })

  it("reports the broker once its complete pair is ready", async () => {
    const result = await runHealthChecks({
      checkDatabase: async () => [{ database_time_millis: Date.now() }],
      checkBroker: () => true,
    })

    expect(result.ok).toBe(true)
    expect(result.checks.broker).toEqual({ ok: true })
  })

  it("still refuses readiness when PostgreSQL is unavailable", async () => {
    const result = await runHealthChecks({
      checkDatabase: async () => { throw new Error("database unavailable") },
      checkBroker: () => true,
    })
    expect(result).toMatchObject({
      ok: false, status: "degraded",
      checks: { database: { ok: false, error: "database_unavailable" }, broker: { ok: true } },
    })
  })

  it("fails readiness when database time proves the protocol clock unsafe", async () => {
    const wall = 1_000_000
    const result = await runHealthChecks({
      checkDatabase: async () => [{ database_time_millis: wall - 21_000 }],
      clock: new InlineProtocolClock({
        wallClock: () => wall,
        monotonicClock: () => 10_000,
      }),
    })

    expect(result).toMatchObject({
      ok: false,
      status: "degraded",
      checks: {
        database: { ok: true },
        clock: {
          ok: false,
          error: "clock_offset_exceeded",
        },
      },
    })
  })
})

describe("shared readiness database probe", () => {
  it("coalesces concurrent requests and refreshes only after database freshness expires", async () => {
    let monotonic = 0
    let probes = 0
    let complete: ((value: unknown) => void) | undefined
    const check = makeHealthChecker({
      checkDatabase: () => {
        probes++
        return new Promise((resolve) => { complete = resolve })
      },
      monotonicClock: () => monotonic,
      clock: new InlineProtocolClock({ wallClock: () => 1_000_000 + monotonic, monotonicClock: () => monotonic }),
    })
    const requests = Array.from({ length: 50 }, () => check())
    expect(probes).toBe(1)
    complete?.([{ database_time_millis: 1_000_000 }])
    expect((await Promise.all(requests)).every((result) => result.ok)).toBe(true)
    monotonic = 999
    expect((await check()).ok).toBe(true)
    expect(probes).toBe(1)
    monotonic = 1_000
    const refreshed = check()
    expect(probes).toBe(2)
    complete?.([{ database_time_millis: 1_001_000 }])
    expect((await refreshed).ok).toBe(true)
  })

  it("waits for a refresh rather than returning stale healthy state after expiry", async () => {
    let monotonic = 0
    let fail: ((error: Error) => void) | undefined
    let probes = 0
    const check = makeHealthChecker({
      checkDatabase: () => ++probes === 1 ? Promise.resolve([]) : new Promise((_resolve, reject) => { fail = reject }),
      monotonicClock: () => monotonic,
    })
    expect((await check()).ok).toBe(true)
    monotonic = 1_000
    const refresh = check()
    const concurrent = check()
    fail?.(new Error("offline"))
    expect((await refresh).checks.database.ok).toBe(false)
    expect((await concurrent).checks.database.ok).toBe(false)
    expect(probes).toBe(2)
  })

  it("bounds failed probes and permits recovery when their freshness expires", async () => {
    let monotonic = 0
    let probes = 0
    const check = makeHealthChecker({
      checkDatabase: () => ++probes === 1 ? Promise.reject(new Error("offline")) : Promise.resolve([]),
      monotonicClock: () => monotonic,
    })
    expect((await check()).ok).toBe(false)
    monotonic = 999
    expect((await check()).ok).toBe(false)
    expect(probes).toBe(1)
    monotonic = 1_000
    expect((await check()).ok).toBe(true)
    expect(probes).toBe(2)
  })

  it("cancels one stalled probe and suppresses replacements even if cancellation throws", async () => {
    let monotonic = 0
    let probes = 0
    let cancellations = 0
    let complete: ((value: unknown) => void) | undefined
    const query = Object.assign(new Promise((resolve) => { complete = resolve }), {
      cancel: () => { cancellations++; throw new Error("cancel failed") },
    })
    const check = makeHealthChecker({
      checkDatabase: () => ++probes === 1 ? query : Promise.resolve([]),
      monotonicClock: () => monotonic,
      timeoutMs: 1,
    })
    const results = await Promise.all(Array.from({ length: 25 }, () => check()))
    expect(results.every((result) => !result.ok)).toBe(true)
    expect(cancellations).toBe(1)
    monotonic = 10_000
    expect((await check()).ok).toBe(false)
    expect(probes).toBe(1)
    // A late success cannot overwrite the authoritative timeout result.
    complete?.([])
    await query
    expect((await check()).ok).toBe(true)
    expect(probes).toBe(2)
  })

  it("holds nested database admission after one child fails while another ignores cancellation", async () => {
    let monotonic = 0
    let probes = 0
    let pooledCancellations = 0
    let migrationCancellations = 0
    let completePooled: (() => void) | undefined
    let composite: Promise<unknown> | undefined
    const pendingPooled = Object.assign(new Promise<void>((resolve) => { completePooled = resolve }), {
      cancel: () => { pooledCancellations++ },
    })
    const migration = Object.assign(Promise.resolve(), { cancel: () => { migrationCancellations++ } })
    const check = makeHealthChecker({
      checkDatabase: () => {
        probes++
        if (probes > 1) return Promise.resolve([])
        const database = combineHealthProbes(Promise.reject(new Error("direct unavailable")), [pendingPooled])
        const probe = combineHealthProbes(database, [migration])
        composite = probe
        return probe
      },
      monotonicClock: () => monotonic,
      timeoutMs: 1,
    })
    try {
      expect((await check()).checks.database.ok).toBe(false)
      expect(pooledCancellations).toBe(1)
      expect(migrationCancellations).toBe(1)
      for (monotonic = 1_000; monotonic <= 5_000; monotonic += 1_000) {
        expect((await check()).checks.database.ok).toBe(false)
      }
      expect(probes).toBe(1)
    } finally {
      completePooled?.()
      await pendingPooled
    }
    if (!composite) throw new Error("Expected the readiness probe to start")
    await expect(composite).rejects.toThrow("direct unavailable")
    expect((await check()).checks.database.ok).toBe(true)
    expect(probes).toBe(2)
  })

  it("advances the cached database timestamp using monotonic time", async () => {
    let monotonic = 0
    const references: (number | undefined)[] = []
    const clock = new InlineProtocolClock({
      wallClock: () => 1_000_000 + monotonic,
      monotonicClock: () => monotonic,
    })
    const check = makeHealthChecker({
      checkDatabase: async () => [{ database_time_millis: 1_000_000 }],
      monotonicClock: () => monotonic,
      clock: { sample: (reference) => { references.push(reference); return clock.sample(reference) } },
    })
    expect((await check()).checks.clock.offsetMillis).toBe(0)
    monotonic = 999
    expect((await check()).checks.clock.offsetMillis).toBe(0)
    expect(references).toEqual([1_000_000, 1_000_999])
  })

  it("resolves optional broker configuration for each response without restarting the probe", async () => {
    let probes = 0
    const check = makeHealthChecker({
      checkDatabase: async () => { probes++; return [] },
      monotonicClock: () => 0,
    })
    expect((await check()).checks.broker).toBeUndefined()
    expect((await check({ checkBroker: () => false })).checks.broker).toEqual({ ok: false, error: "broker_unavailable" })
    expect((await check()).checks.broker).toBeUndefined()
    expect(probes).toBe(1)
  })

  it("resamples clock, broker, and shutdown state while database health is fresh", async () => {
    let monotonic = 0
    let wall = 1_000_000
    let brokerReady = true
    let shuttingDown = false
    let probes = 0
    const check = makeHealthChecker({
      checkDatabase: async () => { probes++; return [{ database_time_millis: wall }] },
      monotonicClock: () => monotonic,
      clock: new InlineProtocolClock({ wallClock: () => wall, monotonicClock: () => monotonic }),
      checkBroker: () => brokerReady,
    })
    const lifecycle = { getShutdownState: () => ({ shuttingDown, signal: "SIGTERM" as const, startedAtMs: wall }) }
    expect(withLifecycleCheck(await check(), lifecycle).ok).toBe(true)
    brokerReady = false
    shuttingDown = true
    const draining = withLifecycleCheck(await check(), lifecycle)
    expect(draining).toMatchObject({ draining: true, ok: false, checks: { database: { ok: true }, broker: { ok: false } } })
    shuttingDown = false
    monotonic = 500
    wall += 21_000
    expect((await check()).checks.clock).toMatchObject({ ok: false, error: "clock_step_detected" })
    expect(probes).toBe(1)
  })
})
