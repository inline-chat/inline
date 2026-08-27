import { describe, expect, it } from "@effect/vitest"
import { Schema } from "effect"
import { BotChat, BotChatParticipant, BotMessageAction, BotUpdate } from "./types.effect"

const chat = {
  chat_id: 10,
  type: "thread",
  title: "Deployments",
  parent_chat_id: 9,
  parent_message: {
    message_id: 40,
    peer_id: { chat_id: 9 },
    chat_id: 9,
    peer: { thread_id: 9 },
    from_id: 7,
    from: { id: 7, is_bot: false, first_name: "Maya" },
    date: 1_785_999_900,
    text: "Deployment context",
  },
} as const

const message = {
  message_id: 41,
  peer_id: { chat_id: chat.chat_id },
  chat_id: chat.chat_id,
  chat,
  peer: {},
  from_id: 7,
  from: { id: 7, is_bot: false, first_name: "Maya" },
  date: 1_786_000_000,
  edit_date: 1_786_000_010,
  text: "Ship it",
  media: { type: "nudge" },
  actions: [[{ action_id: "ship", text: "Ship", type: "callback" }]],
  reactions: [{ emoji: "👍", count: 2, chosen: true }],
} as const

const decodeUpdate = Schema.decodeUnknownSync(BotUpdate)

describe("BotUpdate", () => {
  it("decodes one canonical message event", () => {
    const update = decodeUpdate({
      update_id: 1,
      activation_reason: "mention",
      activated_agent: {
        id: 73,
        bot_user_id: 20,
        name: "Data Analyst",
        instructions: "Show the source.",
      },
      message,
    })

    expect("message" in update).toBe(true)
    expect(update.activated_agent?.id).toBe(73)
  })

  it("decodes the Inline-native bot participation event", () => {
    const update = decodeUpdate({
      update_id: 2,
      bot_participation: {
        chat,
        date: 1_786_000_020,
        status: "added",
      },
    })

    expect("bot_participation" in update).toBe(true)
  })

  it("rejects an update containing more than one event key", () => {
    expect(() =>
      decodeUpdate({
        update_id: 3,
        message,
        edited_message: message,
      }),
    ).toThrow()
  })

  it("rejects unsupported deleted-message updates", () => {
    expect(() =>
      decodeUpdate({
        update_id: 4,
        deleted_messages: {
          chat,
          message_ids: [message.message_id],
          date: 1_786_000_030,
        },
      }),
    ).toThrow()
  })

  it("rejects ambiguous action payload encodings", () => {
    expect(() =>
      decodeUpdate({
        update_id: 5,
        activation_reason: "action",
        message_action: {
          interaction_id: 20,
          chat,
          message_id: message.message_id,
          actor: message.from,
          date: 1_786_000_030,
          action: {
            action_id: "ship",
            callback_data: "ship",
            callback_data_base64: "c2hpcA==",
          },
        },
      }),
    ).toThrow()
  })
})

describe("BotMessageAction", () => {
  it("rejects ambiguous callback payload encodings", () => {
    expect(() =>
      Schema.decodeUnknownSync(BotMessageAction)({
        action_id: "ship",
        text: "Ship",
        type: "callback",
        callback_data: "ship",
        callback_data_base64: "c2hpcA==",
      }),
    ).toThrow()
  })
})

describe("BotChatParticipant", () => {
  it("allows a participant without a space membership", () => {
    expect(Schema.decodeUnknownSync(BotChatParticipant)({
      user: { id: 7, is_bot: false },
    })).toEqual({ user: { id: 7, is_bot: false } })
  })

  it("includes an existing space membership without inventing chat status", () => {
    const participant = Schema.decodeUnknownSync(BotChatParticipant)({
      user: { id: 7, is_bot: false },
      member: {
        id: 12,
        space_id: 4,
        user_id: 7,
        role: "admin",
        date: 1_786_000_000,
        can_access_public_chats: true,
      },
    })
    expect(participant.member?.role).toBe("admin")
  })

  it("serializes a normal parent message at one bounded level", () => {
    const decoded = Schema.decodeUnknownSync(BotChat)(chat)
    const serialized = JSON.stringify(decoded)

    expect(serialized).toContain('"parent_message"')
    expect(decoded.parent_message).not.toHaveProperty("chat")
    expect(decoded.parent_message).not.toHaveProperty("reply_to_message")
    expect(serialized.length).toBeLessThan(1_000)
  })
})
