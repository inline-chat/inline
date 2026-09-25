import { describe, expect, it } from "bun:test"
import { InlineProtocolClock } from "@in/server/modules/inlineProtocol/clockHealth"
import { runHealthChecks } from "./healthCheck"

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
