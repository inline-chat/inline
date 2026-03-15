import { beforeEach, describe, expect, test } from "bun:test"
import { setupTestLifecycle, defaultTestContext, testUtils } from "../setup"
import type { FunctionContext } from "../../functions/_types"
import { createBot } from "../../functions/createBot"
import { getBotCommands } from "../../functions/bot.getCommands"
import { getPeerBotCommands } from "../../functions/bot.getPeerCommands"
import { setBotCommands } from "../../functions/bot.setCommands"
import { ChatModel } from "../../db/models/chats"

describe("bot commands", () => {
  setupTestLifecycle()

  let creator: any
  let otherUser: any
  let creatorContext: FunctionContext
  let otherContext: FunctionContext

  beforeEach(async () => {
    creator = await testUtils.createUser("botcommands-creator@example.com")
    otherUser = await testUtils.createUser("botcommands-other@example.com")

    creatorContext = {
      currentSessionId: defaultTestContext.sessionId,
      currentUserId: creator.id,
    }

    otherContext = {
      currentSessionId: defaultTestContext.sessionId,
      currentUserId: otherUser.id,
    }
  })

  test("creator can replace and fetch bot commands in stable order", async () => {
    const created = await createBot({ name: "Commands Bot", username: "commandstestbot" }, creatorContext)
    const botUserId = created.bot?.id ?? 0n

    const setResult = await setBotCommands(
      {
        botUserId,
        commands: [
          { command: "help", description: "Show help", sortOrder: 20 },
          { command: "start", description: "Start the bot", sortOrder: 10 },
        ],
      },
      creatorContext,
    )

    expect(setResult.commands.map((command) => command.command)).toEqual(["start", "help"])

    const getResult = await getBotCommands({ botUserId }, creatorContext)
    expect(getResult.commands.map((command) => command.command)).toEqual(["start", "help"])
    expect(getResult.commands.map((command) => command.sortOrder)).toEqual([10, 20])
  })

  test("setBotCommands rejects non-owner", async () => {
    const created = await createBot({ name: "Private Commands Bot", username: "privatecommandstestbot" }, creatorContext)

    await expect(
      setBotCommands(
        {
          botUserId: created.bot?.id ?? 0n,
          commands: [{ command: "start", description: "Start the bot" }],
        },
        otherContext,
      ),
    ).rejects.toThrow()
  })

  test("setBotCommands rejects invalid command names", async () => {
    const created = await createBot({ name: "Invalid Commands Bot", username: "invalidcommandstestbot" }, creatorContext)

    await expect(
      setBotCommands(
        {
          botUserId: created.bot?.id ?? 0n,
          commands: [{ command: "Start", description: "Uppercase should fail" }],
        },
        creatorContext,
      ),
    ).rejects.toThrow()
  })

  test("setBotCommands rejects duplicate command names", async () => {
    const created = await createBot({ name: "Duplicate Commands Bot", username: "duplicatecommandstestbot" }, creatorContext)

    await expect(
      setBotCommands(
        {
          botUserId: created.bot?.id ?? 0n,
          commands: [
            { command: "start", description: "Start the bot" },
            { command: "start", description: "Duplicate start" },
          ],
        },
        creatorContext,
      ),
    ).rejects.toThrow()
  })

  test("getPeerBotCommands returns commands for a DM with a bot", async () => {
    const created = await createBot({ name: "Peer Commands Bot", username: "peercommandstestbot" }, creatorContext)
    const botUserId = Number(created.bot?.id ?? 0n)

    await setBotCommands(
      {
        botUserId: BigInt(botUserId),
        commands: [{ command: "start", description: "Start the bot" }],
      },
      creatorContext,
    )

    await ChatModel.createUserChatAndDialog({
      peerUserId: botUserId,
      currentUserId: creator.id,
    })

    const result = await getPeerBotCommands(
      {
        peerId: {
          type: {
            oneofKind: "user",
            user: { userId: BigInt(botUserId) },
          },
        },
      },
      creatorContext,
    )

    expect(result.bots).toHaveLength(1)
    const firstBot = result.bots[0]
    if (!firstBot) {
      throw new Error("Expected a bot command group")
    }
    expect(firstBot.bot?.username).toBe("peercommandstestbot")
    expect((firstBot.commands ?? []).map((command) => command?.command)).toEqual(["start"])
  })
})
