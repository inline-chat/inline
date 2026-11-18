import type { ReactionSummary } from "@inline/core-protocol"
import { describe, expect, it } from "vitest"
import { reactionChipLabel } from "../emoji/display"
import { compareCodePoints, orderReactions, reactionChipTooltip, reactionLabel } from "./reactions"

const reaction = (emoji: string, count: number, mine = false): ReactionSummary => ({ emoji, count, mine })

describe("orderReactions", () => {
  it("orders by count, highest first, then by emoji", () => {
    const ordered = orderReactions([reaction("😂", 1), reaction("👍", 3), reaction("❤️", 3), reaction("🎉", 2)])
    expect(ordered.map((r) => r.emoji)).toEqual(["❤️", "👍", "🎉", "😂"])
  })

  it("compares emoji by code point, not UTF-16 unit, as Swift does", () => {
    // U+FF01 sorts before U+1F600 by code point; by UTF-16 unit the surrogate 0xD83D would win.
    expect(compareCodePoints("！", "😀")).toBeLessThan(0)
    expect(["😀", "！"].sort()).toEqual(["😀", "！"])
    expect(orderReactions([reaction("😀", 1), reaction("！", 1)]).map((r) => r.emoji)).toEqual(["！", "😀"])
    expect(compareCodePoints("👍", "👍🏽")).toBeLessThan(0)
    expect(compareCodePoints("a", "a")).toBe(0)
  })

  it("drops empty reactions and keeps the input untouched", () => {
    const input = [reaction("👍", 0), reaction("🎉", 1)]
    expect(orderReactions(input).map((r) => r.emoji)).toEqual(["🎉"])
    expect(input.map((r) => r.emoji)).toEqual(["👍", "🎉"])
  })

  it("returns the same array for the same reactions, and a shared empty one for none", () => {
    const input = [reaction("👍", 2), reaction("🎉", 1)]
    expect(orderReactions(input)).toBe(orderReactions(input))
    expect(orderReactions(undefined)).toBe(orderReactions([]))
  })

  it("labels chips with the count and whether the viewer reacted", () => {
    expect(reactionLabel(reaction("👍", 3, true))).toBe("👍 3, including you")
    expect(reactionLabel(reaction("👍", 1))).toBe("👍 1")
  })

  it("names a chip by the emoji's name once the data is there, and says who reacted only when it knows", () => {
    expect(reactionChipLabel({ emoji: "👍", count: 3, mine: true }, undefined)).toBe("👍, 3, including you")
    const engine = { lookup: (emoji: string) => (emoji === "👍" ? { label: "thumbs up" } : undefined) } as unknown as Parameters<
      typeof reactionChipLabel
    >[1]
    expect(reactionChipLabel({ emoji: "👍", count: 3, mine: true }, engine)).toBe("thumbs up, 3, including you")
    // No reactor list on the row: "You" only when the viewer is the one reactor.
    expect(reactionChipTooltip(reaction("👍", 1, true), undefined, "1")).toBe("You")
    expect(reactionChipTooltip(reaction("👍", 2, true), undefined, "1")).toBeUndefined()
    expect(reactionChipTooltip(reaction("👍", 1), undefined, "1")).toBeUndefined()
    const reactors = [
      { userId: "2", name: "Ada" },
      { userId: "1", name: "Mo" },
    ]
    expect(reactionChipTooltip(reaction("👍", 2, true), reactors, "1")).toBe("Ada, You")
  })
})
