import { afterEach, describe, expect, spyOn, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { RequestBotFilesystemInput_Operation, type InputPeer } from "@inline-chat/protocol/core"
import { db, schema } from "../../db"
import { BotCapabilitiesModel } from "../../db/models/botCapabilities"
import { createBot } from "../../functions/createBot"
import { requestBotChatSettings } from "../../functions/bot.requestChatSettings"
import { invokeBotChatSettingsItem } from "../../functions/bot.invokeChatSettingsItem"
import { requestBotFilesystem } from "../../functions/bot.filesystem"
import { botChatSettingsBroker } from "../../modules/botChatSettings/broker"
import { botFilesystemBroker } from "../../modules/botFilesystem/broker"
import * as realtime from "../../realtime/message"
import { setupTestLifecycle, testUtils } from "../setup"

describe("private bot replies retain current authorization", () => {
  setupTestLifecycle()
  const spies: { mockRestore(): void }[] = []
  afterEach(() => {
    for (const spy of spies.splice(0)) spy.mockRestore()
    botChatSettingsBroker.shutdown()
    botFilesystemBroker.shutdown()
  })

  async function fixture() {
    const actor = await testUtils.createUser("private-reply-owner@example.com")
    const context = { currentUserId: actor.id, currentSessionId: 1 }
    const created = await createBot({ name: "Reply Bot", username: "private_reply_test_bot" }, context)
    const botId = Number(created.bot!.id)
    await BotCapabilitiesModel.replaceForBotUserId(botId, [{ kind: "chat_settings", version: 1 }])
    const chat = await testUtils.createChat(null, "Private reply", "thread", false, actor.id)
    if (!chat) throw new Error("Missing test chat")
    await testUtils.addParticipant(chat.id, actor.id)
    await testUtils.addParticipant(chat.id, botId)
    const peerId: InputPeer = { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }
    spies.push(spyOn(realtime, "getRealtimeBotConnection").mockReturnValue({ connectionId: "private-bot", sessionId: 2 }))
    return { actor, context, botId, chat, peerId }
  }

  for (const operation of ["request", "mutation"] as const) {
    test(`${operation} rejects a reply after the actor loses chat access`, async () => {
      const { actor, context, botId, chat, peerId } = await fixture()
      spies.push(spyOn(realtime, "sendMessageToRealtimeBotConnection").mockImplementation(async (_bot, _connection, payload) => {
        if (payload.oneofKind !== "bot") throw new Error("Expected bot dispatch")
        const event = payload.bot.event
        const requestId = event.oneofKind === "chatSettingsRequested" ? event.chatSettingsRequested.requestId
          : event.oneofKind === "chatSettingsItemInvoked" ? event.chatSettingsItemInvoked.requestId : undefined
        if (!requestId) throw new Error("Expected settings request")
        await db.delete(schema.chatParticipants).where(and(
          eq(schema.chatParticipants.chatId, chat.id), eq(schema.chatParticipants.userId, actor.id),
        ))
        botChatSettingsBroker.answer(requestId, botId, {
          result: { oneofKind: "document", document: { version: 1, revision: "private", sections: [] } },
        })
        return true
      }))
      const input = { peerId, botUserId: BigInt(botId), version: 1 }
      const result = operation === "request" ? requestBotChatSettings(input, context)
        : invokeBotChatSettingsItem({ ...input, itemId: "refresh", documentRevision: "initial" }, context)
      await expect(result).rejects.toThrow()
      expect(botChatSettingsBroker.pendingCount).toBe(0)
    })
  }

  test("filesystem ownership alone cannot retain access to a removed chat", async () => {
    const { actor, context, botId, chat, peerId } = await fixture()
    spies.push(spyOn(realtime, "sendMessageToRealtimeBotConnection").mockImplementation(async (_bot, connection, payload) => {
      if (payload.oneofKind !== "bot" || payload.bot.event.oneofKind !== "filesystemRequested") {
        throw new Error("Expected filesystem dispatch")
      }
      await db.delete(schema.chatParticipants).where(and(
        eq(schema.chatParticipants.chatId, chat.id), eq(schema.chatParticipants.userId, actor.id),
      ))
      botFilesystemBroker.answer(payload.bot.event.filesystemRequested.requestId, botId, connection, {
        result: { oneofKind: "listing", listing: { path: "/private", entries: [] } },
      })
      return true
    }))
    await expect(requestBotFilesystem({
      peerId, botUserId: BigInt(botId), hostInstallationId: "test-host",
      operation: RequestBotFilesystemInput_Operation.LIST, path: "", after: "",
    }, context)).rejects.toThrow()
  })

  test("still returns the private document while authorization remains valid", async () => {
    const { context, botId, peerId } = await fixture()
    spies.push(spyOn(realtime, "sendMessageToRealtimeBotConnection").mockImplementation(async (_bot, _connection, payload) => {
      if (payload.oneofKind !== "bot" || payload.bot.event.oneofKind !== "chatSettingsRequested") {
        throw new Error("Expected settings dispatch")
      }
      botChatSettingsBroker.answer(payload.bot.event.chatSettingsRequested.requestId, botId, {
        result: { oneofKind: "document", document: { version: 1, revision: "valid", sections: [] } },
      })
      return true
    }))
    const result = await requestBotChatSettings({ peerId, botUserId: BigInt(botId), version: 1 }, context)
    expect(result.response?.result).toMatchObject({ oneofKind: "document", document: { revision: "valid" } })
  })
})
