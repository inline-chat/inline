import { afterEach, describe, expect, spyOn, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { RequestBotFilesystemInput_Operation, type InputPeer } from "@inline-chat/protocol/core"
import { db, schema } from "../../db"
import { BotCapabilitiesModel } from "../../db/models/botCapabilities"
import { createBot } from "../../functions/createBot"
import { requestBotChatSettings } from "../../functions/bot.requestChatSettings"
import { invokeBotChatSettingsItem } from "../../functions/bot.invokeChatSettingsItem"
import { requestBotFilesystem } from "../../functions/bot.filesystem"
import { getBotConfigurationCatalog } from "../../functions/bot.getConfigurationCatalog"
import { getPeerBots } from "../../functions/bot.getPeerBots"
import { AgentConfigurationCatalog } from "@inline-chat/protocol/core"
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

  async function fixture(botParticipant = true) {
    const actor = await testUtils.createUser("private-reply-owner@example.com")
    const context = { currentUserId: actor.id, currentSessionId: 1 }
    const created = await createBot({ name: "Reply Bot", username: "private_reply_test_bot" }, context)
    const botId = Number(created.bot!.id)
    await BotCapabilitiesModel.replaceForBotUserId(botId, [{ kind: "chat_settings", version: 1 }])
    const chat = await testUtils.createChat(null, "Private reply", "thread", false, actor.id)
    if (!chat) throw new Error("Missing test chat")
    await testUtils.addParticipant(chat.id, actor.id)
    if (botParticipant) await testUtils.addParticipant(chat.id, botId)
    const peerId: InputPeer = { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }
    spies.push(spyOn(realtime, "getRealtimeBotConnection").mockReturnValue({ connectionId: "private-bot", sessionId: 2 }))
    return { actor, context, botId, chat, peerId }
  }

  for (const operation of ["request", "mutation"] as const) {
    test(`${operation} configures an owned agent before its first message without joining it`, async () => {
      const { context, botId, chat, peerId } = await fixture(false)
      spies.push(spyOn(realtime, "sendMessageToRealtimeBotConnection").mockImplementation(async (_bot, _connection, payload) => {
        if (payload.oneofKind !== "bot") throw new Error("Expected bot dispatch")
        const event = payload.bot.event
        const request = event.oneofKind === "chatSettingsRequested" ? event.chatSettingsRequested
          : event.oneofKind === "chatSettingsItemInvoked" ? event.chatSettingsItemInvoked : undefined
        if (!request) throw new Error("Expected settings request")
        expect(request.chatId).toBe(BigInt(chat.id))
        expect(request.actorUserId).toBe(BigInt(context.currentUserId))
        botChatSettingsBroker.answer(request.requestId, botId, {
          result: { oneofKind: "document", document: { version: 1, revision: "before-first-message", sections: [] } },
        })
        return true
      }))
      const input = { peerId, botUserId: BigInt(botId), version: 1 }
      const result = operation === "request" ? await requestBotChatSettings(input, context)
        : await invokeBotChatSettingsItem({ ...input, itemId: "workspace.project", documentRevision: "initial" }, context)
      expect(result.response?.result).toMatchObject({ oneofKind: "document", document: { revision: "before-first-message" } })
      expect((await getPeerBots({ peerId }, context)).bots).toEqual([])
      expect(botChatSettingsBroker.pendingCount).toBe(0)
    })
  }

  test("an owned agent's catalog is available before joining the thread", async () => {
    const { context, botId, peerId } = await fixture(false)
    const catalog = AgentConfigurationCatalog.create({
      projects: { options: [{ id: "inline", label: "inline" }], defaultProjectId: "inline" },
    })
    await BotCapabilitiesModel.replaceForBotUserId(botId, [
      { kind: "chat_settings", version: 1 },
      { kind: "agent_configuration", version: 1, payload: AgentConfigurationCatalog.toBinary(catalog) },
    ])
    expect((await getBotConfigurationCatalog({ peerId, botUserId: BigInt(botId) }, context)).catalog).toEqual(catalog)
    expect((await getPeerBots({ peerId }, context)).bots).toEqual([])
  })

  test("a chat member cannot configure another owner's unjoined agent", async () => {
    const { botId, chat, peerId } = await fixture(false)
    const member = await testUtils.createUser("compose-settings-member@example.test")
    await testUtils.addParticipant(chat.id, member.id)
    const context = { currentUserId: member.id, currentSessionId: 1 }
    await expect(requestBotChatSettings({ peerId, botUserId: BigInt(botId), version: 1 }, context)).rejects.toThrow()
    await expect(getBotConfigurationCatalog({ peerId, botUserId: BigInt(botId) }, context)).rejects.toThrow()
    expect(botChatSettingsBroker.pendingCount).toBe(0)
  })

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
