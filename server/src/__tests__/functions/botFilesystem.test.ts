import { describe, expect, test } from "bun:test"
import { BotCapabilitiesModel } from "../../db/models/botCapabilities"
import { ChatModel } from "../../db/models/chats"
import { createBot } from "../../functions/createBot"
import { requestBotFilesystem } from "../../functions/bot.filesystem"
import { setupTestLifecycle, testUtils } from "../setup"
import { RequestBotFilesystemInput_Operation as Operation } from "@inline-chat/protocol/core"

describe("remote filesystem ownership", () => {
  setupTestLifecycle()
  test("a chat participant cannot browse another user's bot host", async () => {
    const owner = await testUtils.createUser("filesystem-owner@example.com")
    const stranger = await testUtils.createUser("filesystem-stranger@example.com")
    const created = await createBot({ name: "Filesystem Bot", username: "filesystemtestbot" }, { currentUserId: owner.id, currentSessionId: 1 })
    const botID = created.bot!.id
    await BotCapabilitiesModel.replaceForBotUserId(Number(botID), [{ kind: "chat_settings", version: 1 }])
    await ChatModel.createUserChatAndDialog({ peerUserId: Number(botID), currentUserId: stranger.id })
    await expect(requestBotFilesystem({
      peerId: { type: { oneofKind: "user", user: { userId: botID } } },
      botUserId: botID, hostInstallationId: "host-1", operation: Operation.LIST, path: "", after: "",
    }, { currentUserId: stranger.id, currentSessionId: 1 })).rejects.toThrow()
  })
})
