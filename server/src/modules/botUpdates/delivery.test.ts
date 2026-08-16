import { describe, expect, it } from "bun:test"
import { webhookRetryDelayMs } from "./delivery"

describe("bot webhook delivery", () => {
  it("uses bounded increasing retry delays", () => {
    const original = Math.random
    Math.random = () => 0
    try {
      expect(webhookRetryDelayMs(1)).toBe(10_000)
      expect(webhookRetryDelayMs(2)).toBe(30_000)
      expect(webhookRetryDelayMs(9)).toBeLessThanOrEqual(3_600_000)
    } finally {
      Math.random = original
    }
  })
})
