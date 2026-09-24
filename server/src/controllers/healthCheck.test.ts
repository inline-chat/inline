import { describe, expect, it } from "bun:test"
import { InlineProtocolClock } from "@in/server/modules/inlineProtocol/clockHealth"
import { runHealthChecks } from "./healthCheck"

describe("runHealthChecks", () => {
  it("fails readiness while a required broker is unavailable", async () => {
    const result = await runHealthChecks({
      checkDatabase: async () => [{ database_time_millis: Date.now() }],
      brokerRequired: true,
      checkBroker: () => false,
    })

    expect(result).toMatchObject({
      ok: false,
      status: "degraded",
      checks: {
        broker: {
          ok: false,
          error: "broker_unavailable",
        },
      },
    })
  })

  it("reports the required broker once its complete pair is ready", async () => {
    const result = await runHealthChecks({
      checkDatabase: async () => [{ database_time_millis: Date.now() }],
      brokerRequired: true,
      checkBroker: () => true,
    })

    expect(result.ok).toBe(true)
    expect(result.checks.broker).toEqual({ ok: true })
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
