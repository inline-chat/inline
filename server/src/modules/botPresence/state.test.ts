import { describe, expect, test } from "bun:test"
import { BotPresenceState_Kind } from "@inline-chat/protocol/core"
import {
  botPresenceActiveStateTtlMs,
  botPresenceCommentStateTtlMs,
  expireBotPresenceState,
  getBotPresenceState,
  normalizeBotPresenceState,
  setBotPresenceState,
} from "./state"

describe("bot presence state", () => {
  test("expires active states to idle", () => {
    const botUserId = 1001
    const chatId = 2001
    const now = 1_000

    setBotPresenceState(botUserId, chatId, { kind: BotPresenceState_Kind.RUNNING }, now)

    expect(getBotPresenceState(botUserId, chatId, now + botPresenceActiveStateTtlMs - 1)).toEqual({
      kind: BotPresenceState_Kind.RUNNING,
    })
    expect(getBotPresenceState(botUserId, chatId, now + botPresenceActiveStateTtlMs)).toEqual({
      kind: BotPresenceState_Kind.IDLE,
    })
    expect(expireBotPresenceState(botUserId, chatId, now + botPresenceActiveStateTtlMs)).toEqual({
      kind: BotPresenceState_Kind.IDLE,
    })
    expect(expireBotPresenceState(botUserId, chatId, now + botPresenceActiveStateTtlMs + 1)).toBeUndefined()
  })

  test("does not let old expiry clear a refreshed state", () => {
    const botUserId = 1002
    const chatId = 2002

    setBotPresenceState(botUserId, chatId, { kind: BotPresenceState_Kind.RUNNING }, 0)
    setBotPresenceState(botUserId, chatId, { kind: BotPresenceState_Kind.WAITING }, botPresenceActiveStateTtlMs - 10)

    expect(expireBotPresenceState(botUserId, chatId, botPresenceActiveStateTtlMs + 1)).toBeUndefined()
    expect(getBotPresenceState(botUserId, chatId, botPresenceActiveStateTtlMs + 1)).toEqual({
      kind: BotPresenceState_Kind.WAITING,
    })
  })

  test("lets commented states run longer but still expire", () => {
    const botUserId = 1004
    const chatId = 2004
    const now = 10_000

    setBotPresenceState(
      botUserId,
      chatId,
      { kind: BotPresenceState_Kind.RUNNING, comment: "reviewing changes" },
      now,
    )

    expect(getBotPresenceState(botUserId, chatId, now + botPresenceActiveStateTtlMs + 1)).toEqual({
      kind: BotPresenceState_Kind.RUNNING,
      comment: "reviewing changes",
    })
    expect(getBotPresenceState(botUserId, chatId, now + botPresenceCommentStateTtlMs)).toEqual({
      kind: BotPresenceState_Kind.IDLE,
    })
    expect(expireBotPresenceState(botUserId, chatId, now + botPresenceCommentStateTtlMs)).toEqual({
      kind: BotPresenceState_Kind.IDLE,
    })
  })

  test("expires idle comments", () => {
    const botUserId = 1005
    const chatId = 2005
    const now = 20_000

    setBotPresenceState(botUserId, chatId, { kind: BotPresenceState_Kind.IDLE, comment: "done" }, now)

    expect(getBotPresenceState(botUserId, chatId, now + botPresenceCommentStateTtlMs - 1)).toEqual({
      kind: BotPresenceState_Kind.IDLE,
      comment: "done",
    })
    expect(getBotPresenceState(botUserId, chatId, now + botPresenceCommentStateTtlMs)).toEqual({
      kind: BotPresenceState_Kind.IDLE,
    })
    expect(expireBotPresenceState(botUserId, chatId, now + botPresenceCommentStateTtlMs)).toEqual({
      kind: BotPresenceState_Kind.IDLE,
    })
  })

  test("idle clears active state", () => {
    const botUserId = 1003
    const chatId = 2003

    setBotPresenceState(botUserId, chatId, { kind: BotPresenceState_Kind.RUNNING }, 0)
    setBotPresenceState(botUserId, chatId, { kind: BotPresenceState_Kind.IDLE }, 1)

    expect(getBotPresenceState(botUserId, chatId, botPresenceActiveStateTtlMs + 1)).toEqual({
      kind: BotPresenceState_Kind.IDLE,
    })
    expect(expireBotPresenceState(botUserId, chatId, botPresenceActiveStateTtlMs + 1)).toBeUndefined()
  })

  test("normalizes hidden and comments", () => {
    expect(
      normalizeBotPresenceState({
        kind: BotPresenceState_Kind.HIDDEN,
        comment: "  working\n\non   it  ",
      }),
    ).toEqual({
      kind: BotPresenceState_Kind.IDLE,
      comment: "working on it",
    })
  })
})
