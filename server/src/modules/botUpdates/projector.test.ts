import { describe, expect, test } from "bun:test"
import type { BotEventMessage } from "@inline-chat/bot-api-types"
import type { MessageEntities } from "@inline-chat/protocol/core"
import type { DbChat } from "@in/server/db/schema"
import type { DbFullMessage } from "@in/server/db/models/messages"
import { encodeAgentThreadContext } from "@in/server/modules/agentConfiguration"
import {
  activationReason,
  agentMentionTargetForChat,
  hasConsumableAgentContent,
  hasResolvedBoundAgent,
} from "@in/server/modules/botUpdates/projector"

const BOT_ID = 20

const mention = (botUserId = BOT_ID, agentId?: number): MessageEntities => ({
  entities: [{
    type: 2,
    offset: 0n,
    length: 6n,
    entity: {
      oneofKind: "mention",
      mention: { userId: BigInt(botUserId), agentId: agentId === undefined ? undefined : BigInt(agentId) },
    },
  }],
})

const multipleAgentMentions = (...agentIds: number[]): MessageEntities => ({
  entities: agentIds.map((agentId, index) => ({
    type: 2,
    offset: BigInt(index * 7),
    length: 6n,
    entity: {
      oneofKind: "mention" as const,
      mention: { userId: BigInt(BOT_ID), agentId: BigInt(agentId) },
    },
  })),
})

const chat = (bound: boolean, agentId?: number): DbChat => ({
  id: 100,
  type: "thread",
  agentContext: bound
    ? encodeAgentThreadContext({
        botUserId: BigInt(BOT_ID),
        agentId: agentId === undefined ? undefined : BigInt(agentId),
        configuration: undefined,
      })
    : null,
} as DbChat)

const message = (fromId: number, fromBot: boolean, entities?: MessageEntities): DbFullMessage => ({
  fromId,
  from: { id: fromId, bot: fromBot },
  entities: entities ?? null,
} as DbFullMessage)

describe("Bot activation routing", () => {
  test("a bound Chat addresses ordinary human traffic independently of legacy trigger mode", () => {
    expect(activationReason({
      stream: { botUserId: BOT_ID, messageTrigger: "mentions" },
      chat: chat(true, 73),
      message: message(30, false),
      reply: null,
    })).toBe("all")

    expect(activationReason({
      stream: { botUserId: BOT_ID, messageTrigger: "mentions" },
      chat: chat(false),
      message: message(30, false),
      reply: null,
    })).toBeUndefined()
  })

  test("all bot-to-bot activation is exact-mention-only", () => {
    expect(activationReason({
      stream: { botUserId: BOT_ID, messageTrigger: "all" },
      chat: chat(true),
      message: message(30, true),
      reply: null,
    })).toBeUndefined()

    expect(activationReason({
      stream: { botUserId: BOT_ID, messageTrigger: "all" },
      chat: chat(true),
      message: message(30, true, mention()),
      reply: null,
    })).toBe("mention")
  })

  test("same-bot handoff requires a distinct source Chat and bound destination", () => {
    expect(activationReason({
      stream: { botUserId: BOT_ID, messageTrigger: "all" },
      chat: chat(true),
      message: message(BOT_ID, true, mention()),
      reply: null,
      sourceChatId: 90,
    })).toBe("mention")

    expect(activationReason({
      stream: { botUserId: BOT_ID, messageTrigger: "all" },
      chat: chat(true),
      message: message(BOT_ID, true, mention()),
      reply: null,
      sourceChatId: 100,
    })).toBeUndefined()

    expect(activationReason({
      stream: { botUserId: BOT_ID, messageTrigger: "all" },
      chat: chat(false),
      message: message(BOT_ID, true, mention()),
      reply: null,
      sourceChatId: 90,
    })).toBeUndefined()
  })

  test("bot handoff must mention the exact Agent bound to the destination", () => {
    expect(activationReason({
      stream: { botUserId: BOT_ID, messageTrigger: "all" },
      chat: chat(true, 73),
      message: message(30, true, mention(BOT_ID, 73)),
      reply: null,
    })).toBe("mention")

    expect(activationReason({
      stream: { botUserId: BOT_ID, messageTrigger: "all" },
      chat: chat(true, 73),
      message: message(30, true, mention(BOT_ID, 74)),
      reply: null,
    })).toBeUndefined()

    expect(activationReason({
      stream: { botUserId: BOT_ID, messageTrigger: "all" },
      chat: chat(true, 73),
      message: message(BOT_ID, true, mention(BOT_ID, 74)),
      reply: null,
      sourceChatId: 90,
    })).toBeUndefined()
  })

  test("a bound Chat resolves the exact bound Agent rather than the first sibling mention", () => {
    expect(agentMentionTargetForChat(
      multipleAgentMentions(72, 73),
      BOT_ID,
      chat(true, 73),
    )).toBe(73)

    expect(agentMentionTargetForChat(
      multipleAgentMentions(72, 73),
      BOT_ID,
      chat(true),
    )).toBeUndefined()

    expect(agentMentionTargetForChat(undefined, BOT_ID, chat(true, 73))).toBe(73)
  })

  test("only content present in the projected Bot message is consumable", () => {
    expect(hasConsumableAgentContent({ text: "  " } as BotEventMessage)).toBe(false)
    expect(hasConsumableAgentContent({ text: "hello" } as BotEventMessage)).toBe(true)
    expect(hasConsumableAgentContent({ rich_message: {} } as BotEventMessage)).toBe(true)
    expect(hasConsumableAgentContent({ media: { type: "document" } } as BotEventMessage)).toBe(true)
    expect(hasConsumableAgentContent({ media: { type: "nudge" } } as BotEventMessage)).toBe(false)
  })

  test("a missing persisted Agent makes its bound Chat fail closed", () => {
    expect(hasResolvedBoundAgent(chat(true, 73), BOT_ID, undefined)).toBe(false)
    expect(hasResolvedBoundAgent(chat(true), BOT_ID, undefined)).toBe(true)
    expect(hasResolvedBoundAgent(chat(false), BOT_ID, undefined)).toBe(true)
  })
})
