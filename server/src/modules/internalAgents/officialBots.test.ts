import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db, schema } from "@in/server/db"
import { BotCommandsModel } from "@in/server/db/models/botCommands"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import {
  OfficialInternalBotProvisionError,
  provisionOfficialInternalBots,
} from "@in/server/modules/internalAgents/officialBots"

const provisionForTest = () => provisionOfficialInternalBots(undefined, { seedProfilePhotos: false })

describe("official internal bot provisioning", () => {
  setupTestLifecycle()

  test("creates the ChatGPT bot user and /stop command", async () => {
    const [result] = await provisionForTest()

    expect(result).toEqual({
      agentKey: "chatgpt",
      botUserId: expect.any(Number),
      username: "chatgpt",
    })

    const [bot] = await db.select().from(schema.users).where(eq(schema.users.username, "chatgpt"))
    expect(bot).toMatchObject({
      firstName: "ChatGPT",
      username: "chatgpt",
      bot: true,
      botCreatorId: null,
      deleted: false,
      pendingSetup: false,
    })

    const commands = await BotCommandsModel.getForBotUserId(bot!.id)
    expect(commands.map(({ command, description, sortOrder }) => ({ command, description, sortOrder }))).toEqual([
      {
        command: "stop",
        description: "Stop the current ChatGPT run",
        sortOrder: 0,
      },
    ])
  })

  test("is idempotent and keeps the same row ids when already provisioned", async () => {
    const [first] = await provisionForTest()
    const firstCommands = await BotCommandsModel.getForBotUserId(first!.botUserId)

    const [second] = await provisionForTest()
    const secondCommands = await BotCommandsModel.getForBotUserId(second!.botUserId)

    expect(second).toEqual(first)
    expect(secondCommands.map((command) => command.id)).toEqual(firstCommands.map((command) => command.id))
  })

  test("updates official bot defaults and removes stale commands", async () => {
    const [bot] = await db
      .insert(schema.users)
      .values({
        username: "ChatGPT",
        firstName: "Old Name",
        bot: true,
        botCreatorId: null,
        deleted: false,
        pendingSetup: true,
      })
      .returning()

    await db.insert(schema.botCommands).values([
      {
        botUserId: bot!.id,
        command: "stop",
        description: "Old stop",
        sortOrder: 10,
      },
      {
        botUserId: bot!.id,
        command: "stale",
        description: "Remove me",
        sortOrder: 20,
      },
    ])

    const [result] = await provisionForTest()

    expect(result!.botUserId).toBe(bot!.id)

    const [updated] = await db.select().from(schema.users).where(eq(schema.users.id, bot!.id))
    expect(updated).toMatchObject({
      username: "chatgpt",
      firstName: "ChatGPT",
      pendingSetup: false,
    })

    const commands = await BotCommandsModel.getForBotUserId(bot!.id)
    expect(commands.map(({ command, description, sortOrder }) => ({ command, description, sortOrder }))).toEqual([
      {
        command: "stop",
        description: "Stop the current ChatGPT run",
        sortOrder: 0,
      },
    ])
  })

  test("fails closed when chatgpt belongs to a normal user", async () => {
    await db.insert(schema.users).values({
      username: "chatgpt",
      firstName: "Taken",
      bot: false,
      deleted: false,
    })

    await expect(provisionForTest()).rejects.toBeInstanceOf(OfficialInternalBotProvisionError)
  })

  test("fails closed when chatgpt belongs to a user-owned bot", async () => {
    const owner = await testUtils.createUser("owned-chatgpt-bot@example.com")

    await db.insert(schema.users).values({
      username: "chatgpt",
      firstName: "Taken Bot",
      bot: true,
      botCreatorId: owner.id,
      deleted: false,
    })

    await expect(provisionForTest()).rejects.toBeInstanceOf(OfficialInternalBotProvisionError)
  })
})
