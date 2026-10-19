import { describe, expect, test } from "bun:test"
import { IdleBackoff, defaultMaximumIdleIntervalMs } from "./idleBackoff"

describe("IdleBackoff", () => {
  test("doubles the gap after empty polls up to the cap and resets on work or a hint", () => {
    const backoff = IdleBackoff.forInterval(1_000, 10_000)
    expect(backoff.multiplier).toBe(1)
    backoff.observe(false)
    expect(backoff.multiplier).toBe(2)
    backoff.observe(false)
    backoff.observe(false)
    backoff.observe(false)
    expect(backoff.multiplier).toBe(10)
    backoff.observe(true)
    expect(backoff.multiplier).toBe(1)
    backoff.observe(false)
    backoff.reset()
    expect(backoff.multiplier).toBe(1)
  })

  test("fixed-interval ticks skip multiplier minus one ticks between polls", () => {
    const backoff = new IdleBackoff(8)
    expect([backoff.due(), backoff.due()]).toEqual([true, true])
    backoff.observe(false)
    expect([backoff.due(), backoff.due(), backoff.due()]).toEqual([false, true, false])
    backoff.observe(false)
    expect([backoff.due(), backoff.due(), backoff.due(), backoff.due(), backoff.due()]).toEqual([false, false, false, true, false])
    backoff.reset()
    expect(backoff.due()).toBe(true)
  })

  test("the default cap is sixteen base intervals bounded at fifteen seconds", () => {
    expect(defaultMaximumIdleIntervalMs(1_000)).toBe(15_000)
    expect(defaultMaximumIdleIntervalMs(20)).toBe(320)
    expect(IdleBackoff.forInterval(2_500).multiplier).toBe(1)
    expect(() => new IdleBackoff(0)).toThrow(RangeError)
  })
})
