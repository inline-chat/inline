import { beforeEach, describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db, schema } from "../../db"
import { BotCapabilitiesModel } from "../../db/models/botCapabilities"
import { ChatModel } from "../../db/models/chats"
import type { FunctionContext } from "../../functions/_types"
import { answerBotChatSettings } from "../../functions/bot.answerChatSettings"
import { getPeerBots } from "../../functions/bot.getPeerBots"
import { createBotAgent } from "../../functions/bot.agents"
import { createBot } from "../../functions/createBot"
import { createSubthread } from "../../functions/messages.createSubthread"
import { botChatSettingsBroker } from "../../modules/botChatSettings/broker"
import { unreachableBotChatSettingsResponse } from "../../modules/botChatSettings/validation"
import { RealtimeRpcError } from "../../realtime/errors"
import { defaultTestContext, setupTestLifecycle, testUtils } from "../setup"

describe("bot chat settings discovery", () => {
  setupTestLifecycle()

  let creator: any
  let creatorContext: FunctionContext

  beforeEach(async () => {
    creator = await testUtils.createUser("bot-settings-discovery@example.com")
    creatorContext = {
      currentSessionId: defaultTestContext.sessionId,
      currentUserId: creator.id,
    }
  })

  test("discovers a capable bot in a DM", async () => {
    const created = await createBot(
      { name: "Settings DM Bot", username: "settingsdmbot" },
      creatorContext,
    )
    const botUserId = Number(created.bot?.id ?? 0n)
    await BotCapabilitiesModel.replaceForBotUserId(botUserId, [
      { kind: "chat_settings", version: 1 },
    ])
    await ChatModel.createUserChatAndDialog({
      peerUserId: botUserId,
      currentUserId: creator.id,
    })

    const result = await getPeerBots({
      peerId: { type: { oneofKind: "user", user: { userId: BigInt(botUserId) } } },
    }, creatorContext)

    expect(result.bots.map((bot) => bot.bot?.id)).toEqual([BigInt(botUserId)])
    expect(result.bots[0]?.capabilities).toEqual([{ kind: 1, version: 1 }])
    expect(result.suggestedBotUserId).toBe(BigInt(botUserId))
  })

  test("discovers only the client-safe Agent projection through the bot's peer access", async () => {
    const created = await createBot(
      { name: "Agent Discovery Bot", username: "agentdiscoverybot" },
      creatorContext,
    )
    const botUserId = Number(created.bot?.id ?? 0n)
    const createdAgent = await createBotAgent({
      botUserId: BigInt(botUserId),
      name: "Data Analyst",
      emoji: "📊",
      description: "Explains the numbers",
      skillKey: "private-skill-key",
      instructions: "Never disclose this instruction.",
    }, creatorContext)
    const agent = createdAgent.agent
    if (!agent) throw new Error("Expected Agent")
    await ChatModel.createUserChatAndDialog({
      peerUserId: botUserId,
      currentUserId: creator.id,
    })

    const result = await getPeerBots({
      peerId: { type: { oneofKind: "user", user: { userId: BigInt(botUserId) } } },
    }, creatorContext)

    expect(result.bots[0]?.agents).toEqual([{
      id: agent.id,
      botUserId: BigInt(botUserId),
      name: "Data Analyst",
      emoji: "📊",
      description: "Explains the numbers",
    }])
    expect("skillKey" in (result.bots[0]?.agents[0] ?? {})).toBe(false)
    expect("instructions" in (result.bots[0]?.agents[0] ?? {})).toBe(false)
  })

  test("suggests the capable bot with the newest message", async () => {
    const first = await createBot(
      { name: "First Settings Bot", username: "firstsettingsbot" },
      creatorContext,
    )
    const second = await createBot(
      { name: "Second Settings Bot", username: "secondsettingsbot" },
      creatorContext,
    )
    const firstBotUserId = Number(first.bot?.id ?? 0n)
    const secondBotUserId = Number(second.bot?.id ?? 0n)
    await Promise.all([
      BotCapabilitiesModel.replaceForBotUserId(firstBotUserId, [{ kind: "chat_settings", version: 1 }]),
      BotCapabilitiesModel.replaceForBotUserId(secondBotUserId, [{ kind: "chat_settings", version: 1 }]),
    ])

    const chat = await testUtils.createChat(null, "Settings activity", "thread", false, creator.id)
    if (!chat) throw new Error("Expected settings chat")
    await testUtils.addParticipant(chat.id, creator.id)
    await testUtils.addParticipant(chat.id, firstBotUserId)
    await testUtils.addParticipant(chat.id, secondBotUserId)
    await db.insert(schema.messages).values([
      { chatId: chat.id, messageId: 1, fromId: secondBotUserId, text: "older" },
      { chatId: chat.id, messageId: 2, fromId: firstBotUserId, text: "newer" },
    ])

    const result = await getPeerBots({
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } },
    }, creatorContext)

    expect(result.bots.map((bot) => bot.bot?.id)).toEqual([
      BigInt(firstBotUserId),
      BigInt(secondBotUserId),
    ].sort((left, right) => Number(left - right)))
    expect(result.suggestedBotUserId).toBe(BigInt(firstBotUserId))
  })

  test("inherits capable bots from the parent of a reply thread", async () => {
    const created = await createBot(
      { name: "Parent Settings Bot", username: "parentsettingsbot" },
      creatorContext,
    )
    const botUserId = Number(created.bot?.id ?? 0n)
    await BotCapabilitiesModel.replaceForBotUserId(botUserId, [
      { kind: "chat_settings", version: 1 },
    ])

    const parent = await testUtils.createChat(null, "Settings parent", "thread", false, creator.id)
    if (!parent) throw new Error("Expected parent chat")
    await testUtils.addParticipant(parent.id, creator.id)
    await testUtils.addParticipant(parent.id, botUserId)
    await db.insert(schema.messages).values({
      chatId: parent.id,
      messageId: 1,
      fromId: creator.id,
      text: "anchor",
    })
    await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, parent.id))

    const child = await createSubthread({
      parentChatId: BigInt(parent.id),
      parentMessageId: 1n,
    }, creatorContext)
    const result = await getPeerBots({
      peerId: { type: { oneofKind: "chat", chat: { chatId: child.chat.id } } },
    }, creatorContext)

    expect(result.bots.map((bot) => bot.bot?.id)).toEqual([BigInt(botUserId)])
    expect(result.bots[0]?.capabilities).toEqual([{ kind: 1, version: 1 }])
  })

  test("accepts a valid late settings answer after its broker request expired", async () => {
    const created = await createBot(
      { name: "Late Settings Bot", username: "latesettingsbot" },
      creatorContext,
    )
    const botUserId = Number(created.bot?.id ?? 0n)
    const result = await answerBotChatSettings({
      requestId: 9_999_999n,
      response: {
        result: {
          oneofKind: "document",
          document: { version: 1, revision: "late", sections: [] },
        },
      },
    }, {
      currentSessionId: defaultTestContext.sessionId,
      currentUserId: botUserId,
    })

    expect(result).toEqual({})
  })

  test("still rejects a settings answer from the wrong bot", async () => {
    const created = await createBot(
      { name: "Wrong Settings Bot", username: "wrongsettingsbot" },
      creatorContext,
    )
    const botUserId = Number(created.bot?.id ?? 0n)
    const pending = botChatSettingsBroker.create({
      botUserId: botUserId + 1,
      actorUserId: creator.id,
      chatId: 77,
      operation: "request",
    })
    try {
      await expect(answerBotChatSettings({
        requestId: pending.requestId,
        response: {
          result: {
            oneofKind: "document",
            document: { version: 1, revision: "wrong-bot", sections: [] },
          },
        },
      }, {
        currentSessionId: defaultTestContext.sessionId,
        currentUserId: botUserId,
      })).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
    } finally {
      botChatSettingsBroker.resolveSystem(
        pending.requestId,
        unreachableBotChatSettingsResponse(),
        "shutdown",
      )
      await pending.response
    }
  })
})
