import { userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { resolveMessageReactionGroups } from "./MessageReactions"

describe("resolveMessageReactionGroups", () => {
  it("applies ordered optimistic intents without mutating server reactions", () => {
    const state = {
      reactions: [
        { emoji: "👍", userId: userId(8), date: 10 },
      ],
      intents: [
        { id: "1", emoji: "👍", userId: userId(7), action: "add" as const },
        { id: "2", emoji: "👍", userId: userId(7), action: "delete" as const },
        { id: "3", emoji: "❤️", userId: userId(7), action: "add" as const },
      ],
    }

    expect(resolveMessageReactionGroups(state, userId(7))).toEqual([
      {
        emoji: "❤️",
        reactions: [{ emoji: "❤️", userId: userId(7) }],
        weReacted: true,
        pending: true,
      },
      {
        emoji: "👍",
        reactions: [{ emoji: "👍", userId: userId(8), date: 10 }],
        weReacted: false,
        pending: true,
      },
    ])
    expect(state.reactions).toHaveLength(1)
  })

  it("deduplicates by user and follows native count-first ordering", () => {
    const groups = resolveMessageReactionGroups({
      reactions: [
        { emoji: "😂", userId: userId(8), date: 1 },
        { emoji: "👍", userId: userId(8), date: 1 },
        { emoji: "👍", userId: userId(9), date: 2 },
        { emoji: "👍", userId: userId(8), date: 3 },
      ],
      intents: [],
    }, userId(7))

    expect(groups.map((group) => [group.emoji, group.reactions.length])).toEqual([
      ["👍", 2],
      ["😂", 1],
    ])
    expect(groups[0]?.reactions.map(({ userId }) => userId)).toEqual([
      userId(8),
      userId(9),
    ])
  })
})
