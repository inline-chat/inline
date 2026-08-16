import { describe, expect, it } from "bun:test"
import { InlineProtocolClock } from "./clockHealth"

describe("InlineProtocolClock", () => {
  it("warns on database offset, fails at the protocol safety boundary, and latches failure", () => {
    let wall = 1_000_000
    let monotonic = 10_000
    const clock = new InlineProtocolClock({
      wallClock: () => wall,
      monotonicClock: () => monotonic,
    })

    expect(clock.sample(wall - 5_001)).toMatchObject({
      ok: true,
      status: "warning",
      warning: "clock_offset_warning",
    })
    expect(clock.sample(wall - 20_000)).toMatchObject({
      ok: false,
      error: "clock_offset_exceeded",
    })
    expect(clock.sample(wall)).toMatchObject({
      ok: false,
      error: "clock_offset_exceeded",
    })
  })

  it("detects a wall-clock step relative to monotonic time", () => {
    let wall = 1_000_000
    let monotonic = 10_000
    const clock = new InlineProtocolClock({
      wallClock: () => wall,
      monotonicClock: () => monotonic,
    })

    wall += 21_000
    monotonic += 500

    expect(clock.sample()).toMatchObject({
      ok: false,
      error: "clock_step_detected",
      stepMillis: 20_500,
    })
    expect(() => clock.assertHealthy()).toThrow("clock is unhealthy")
  })
})
