import { describe, expect, it } from "vitest"
import { formatLatestCount, latestButtonLabel } from "./format"

describe("formatLatestCount (Mac ChatUnreadBadgeCount.format)", () => {
  it.each([
    [0, "0"],
    [-3, "0"],
    [7, "7"],
    [999, "999"],
    [1_000, "1K"],
    [1_049, "1K"],
    [1_250, "1.2K"],
    [9_999, "9.9K"],
    [10_000, "10K"],
    [12_345, "12K"],
    [250_000, "250K"],
  ])("%i prints as %s", (count, expected) => {
    expect(formatLatestCount(count)).toBe(expected)
  })
})

describe("latestButtonLabel", () => {
  it("names the action and carries the count", () => {
    expect(latestButtonLabel(0)).toBe("Jump to latest")
    expect(latestButtonLabel(1)).toBe("Jump to latest, 1 new message")
    expect(latestButtonLabel(42)).toBe("Jump to latest, 42 new messages")
    expect(latestButtonLabel(1_500)).toBe("Jump to latest, 1.5K new messages")
  })
})
