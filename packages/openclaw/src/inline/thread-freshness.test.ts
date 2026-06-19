import { describe, expect, it } from "vitest"
import { resolveInlineThreadFreshness } from "./thread-freshness"

describe("resolveInlineThreadFreshness", () => {
  it("treats an empty visible history as fresh", () => {
    const result = resolveInlineThreadFreshness({
      messages: [],
      botUserId: 777n,
      botUsername: "inlinebot",
      participantDate: 1_700_000_000n,
    })

    expect(result.kind).toBe("fresh")
    expect(result.reason).toBe("no_pre_join_messages")
    expect(result.preJoinMessages).toEqual([])
    expect(result.priorMentionMessages).toEqual([])
  })

  it("treats user messages before the bot was added as existing history", () => {
    const result = resolveInlineThreadFreshness({
      messages: [
        {
          id: 1n,
          date: 1_699_999_990n,
          fromId: 51n,
          message: "Can someone invite the bot?",
        },
      ],
      botUserId: 777n,
      botUsername: "inlinebot",
      participantDate: 1_700_000_000n,
    })

    expect(result.kind).toBe("existing")
    expect(result.preJoinMessages.map((message) => message.id)).toEqual([1n])
    expect(result.priorMentionMessages).toEqual([])
  })

  it("treats same-second user messages as existing history", () => {
    const result = resolveInlineThreadFreshness({
      messages: [
        {
          id: 1n,
          date: 1_700_000_000n,
          fromId: 51n,
          message: "@inlinebot please review this once added",
        },
      ],
      botUserId: 777n,
      botUsername: "inlinebot",
      participantDate: 1_700_000_000n,
    })

    expect(result.kind).toBe("existing")
    expect(result.preJoinMessages.map((message) => message.id)).toEqual([1n])
    expect(result.priorMentionMessages.map((message) => message.id)).toEqual([1n])
  })

  it("treats pre-join media as existing history", () => {
    const result = resolveInlineThreadFreshness({
      messages: [
        {
          id: 1n,
          date: 1_699_999_990n,
          fromId: 51n,
          media: { oneofKind: "voice" },
        },
      ],
      botUserId: 777n,
      botUsername: "inlinebot",
      participantDate: 1_700_000_000n,
    })

    expect(result.kind).toBe("existing")
    expect(result.preJoinMessages.map((message) => message.id)).toEqual([1n])
  })

  it("ignores messages from the bot and messages after the join event", () => {
    const result = resolveInlineThreadFreshness({
      messages: [
        {
          id: 1n,
          date: 1_699_999_990n,
          fromId: 777n,
          message: "old bot message from a replayed history",
        },
        {
          id: 2n,
          date: 1_700_000_010n,
          fromId: 51n,
          message: "message after the add event",
        },
      ],
      botUserId: 777n,
      botUsername: "inlinebot",
      participantDate: 1_700_000_000n,
    })

    expect(result.kind).toBe("fresh")
    expect(result.preJoinMessages).toEqual([])
  })

  it("tracks prior bot mentions by username and entity", () => {
    const result = resolveInlineThreadFreshness({
      messages: [
        {
          id: 1n,
          date: 1_699_999_990n,
          fromId: 51n,
          message: "@InlineBot please review this once added",
        },
        {
          id: 2n,
          date: 1_699_999_991n,
          fromId: 52n,
          message: "also tagging by entity",
          entities: {
            entities: [
              {
                entity: {
                  oneofKind: "mention",
                  mention: { userId: 777n },
                },
              },
            ],
          },
        },
      ],
      botUserId: 777n,
      botUsername: "@inlinebot",
      participantDate: 1_700_000_000n,
    })

    expect(result.kind).toBe("existing")
    expect(result.priorMentionMessages.map((message) => message.id)).toEqual([1n, 2n])
  })

  it("returns unknown when history could not be loaded", () => {
    const result = resolveInlineThreadFreshness({
      messages: null,
      botUserId: 777n,
      botUsername: "inlinebot",
      participantDate: 1_700_000_000n,
    })

    expect(result.kind).toBe("unknown")
    expect(result.reason).toBe("history_unavailable")
  })
})
