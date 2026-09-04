import { beforeEach, describe, expect, test } from "bun:test"
import type { AgentThreadContext, MessageEntities } from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { BotAgentsModel } from "@in/server/db/models/botAgents"
import { chats, messages, users } from "@in/server/db/schema"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { decodeAgentThreadContext, encodeAgentThreadContext } from "@in/server/modules/agentConfiguration"
import { eq } from "drizzle-orm"

describe("messages.sendMessage Agent thread context", () => {
  setupTestLifecycle()

  let ownerId = 0
  let botId = 0
  let chatId = 0
  let context: AgentThreadContext

  beforeEach(async () => {
    const owner = await testUtils.createUser(`agent-context-owner-${crypto.randomUUID()}@example.com`)
    const bot = await testUtils.createUser(`agent-context-bot-${crypto.randomUUID()}@example.com`)
    const chat = await testUtils.createChat(null, "Agent context", "thread", false, owner.id)
    if (!chat) throw new Error("chat not created")
    ownerId = owner.id
    botId = bot.id
    chatId = chat.id
    await db.update(users).set({ bot: true, botCreatorId: owner.id }).where(eq(users.id, bot.id))
    await Promise.all([
      testUtils.addParticipant(chat.id, owner.id),
      testUtils.addParticipant(chat.id, bot.id),
    ])
    context = { botUserId: BigInt(bot.id) }
  })

  test("concurrently retries the atomic first binding with the same random ID", async () => {
    const input = {
      peerId: { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chatId) } } },
      message: "Run this",
      initialAgentContext: context,
      randomId: 912_345n,
    }
    const functionContext = testUtils.functionContext({ userId: ownerId, sessionId: 1 })

    const results = await Promise.all([
      sendMessage(input, functionContext),
      sendMessage(input, functionContext),
    ])

    expect(results).toHaveLength(2)
    expect(await db.select().from(messages).where(eq(messages.chatId, chatId))).toHaveLength(1)
  })

  test("recovers a retry after an unavailable Agent was cleared", async () => {
    const otherBot = await testUtils.createUser(`agent-context-other-bot-${crypto.randomUUID()}@example.com`)
    await db.update(users).set({ bot: true, botCreatorId: ownerId }).where(eq(users.id, otherBot.id))
    const unavailableAgent = await BotAgentsModel.create({ botUserId: otherBot.id, name: "Other Agent" })
    const input = {
      peerId: { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chatId) } } },
      message: "Run this once",
      initialAgentContext: {
        botUserId: BigInt(botId),
        agentId: unavailableAgent.id,
      },
      randomId: 912_351n,
    }
    const functionContext = testUtils.functionContext({ userId: ownerId, sessionId: 1 })

    await sendMessage(input, functionContext)
    await sendMessage(input, functionContext)

    const [stored] = await db.select().from(chats).where(eq(chats.id, chatId)).limit(1)
    expect(decodeAgentThreadContext(stored?.agentContext ?? null)).toEqual({
      botUserId: BigInt(botId),
      agentId: undefined,
      configuration: undefined,
    })
    expect(await db.select().from(messages).where(eq(messages.chatId, chatId))).toHaveLength(1)
  })

  test("uses the typed initial target without injecting a text mention", async () => {
    const agent = await BotAgentsModel.create({ botUserId: botId, name: "Specialist" })
    await sendMessage({
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } },
      message: "Run this",
      initialAgentContext: { botUserId: BigInt(botId), agentId: agent.id },
      randomId: 912_346n,
    }, testUtils.functionContext({ userId: ownerId, sessionId: 1 }))

    const [stored] = await db.select().from(chats).where(eq(chats.id, chatId)).limit(1)
    expect(decodeAgentThreadContext(stored?.agentContext ?? null)).toEqual({
      botUserId: BigInt(botId),
      agentId: agent.id,
      configuration: undefined,
    })
  })

  test("only the provider owner may create the human binding", async () => {
    const teammate = await testUtils.createUser(`agent-context-teammate-${crypto.randomUUID()}@example.com`)
    await testUtils.addParticipant(chatId, teammate.id)

    await expect(sendMessage({
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } },
      message: "Run this",
      initialAgentContext: context,
      randomId: 912_347n,
    }, testUtils.functionContext({ userId: teammate.id, sessionId: 1 }))).rejects.toBeInstanceOf(Error)

    const [stored] = await db.select().from(chats).where(eq(chats.id, chatId)).limit(1)
    expect(stored?.agentContext).toBeNull()
    expect(await db.select().from(messages).where(eq(messages.chatId, chatId))).toHaveLength(0)
  })

  test("same-message recovery survives a later configuration replacement", async () => {
    const input = {
      peerId: { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chatId) } } },
      message: "Run this",
      initialAgentContext: context,
      randomId: 912_348n,
    }
    const functionContext = testUtils.functionContext({ userId: ownerId, sessionId: 1 })
    await sendMessage(input, functionContext)
    await db.update(chats).set({
      agentContext: encodeAgentThreadContext({
        ...context,
        configuration: { modelId: "new-model" },
      }),
    }).where(eq(chats.id, chatId))

    await sendMessage(input, functionContext)

    expect(await db.select().from(messages).where(eq(messages.chatId, chatId))).toHaveLength(1)
  })

  test("a same-bot exact mention requires validated cross-Chat provenance", async () => {
    await sendMessage({
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } },
      message: "Bind this",
      initialAgentContext: context,
      randomId: 912_349n,
    }, testUtils.functionContext({ userId: ownerId, sessionId: 1 }))
    const entities: MessageEntities = {
      entities: [{
        type: 2,
        offset: 0n,
        length: 6n,
        entity: {
          oneofKind: "mention",
          mention: { userId: BigInt(botId), agentId: undefined },
        },
      }],
    }

    await expect(sendMessage({
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } },
      message: "@agent continue",
      entities,
      randomId: 912_350n,
    }, testUtils.functionContext({ userId: botId, sessionId: 2 }))).rejects.toBeInstanceOf(Error)

    expect(await db.select().from(messages).where(eq(messages.chatId, chatId))).toHaveLength(1)
  })
})
