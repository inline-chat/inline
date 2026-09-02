import { beforeEach, describe, expect, test } from "bun:test"
import { BotSkillsModel } from "@in/server/db/models/botSkills"
import { createBot } from "@in/server/functions/createBot"
import { getBotSkills } from "@in/server/functions/bot.getSkills"
import { defaultTestContext, setupTestLifecycle, testUtils } from "../setup"

describe("bot skills", () => {
  setupTestLifecycle()

  let creatorUserId: number
  let otherUserId: number

  beforeEach(async () => {
    creatorUserId = (await testUtils.createUser(`skill-creator-${Date.now()}@example.com`)).id
    otherUserId = (await testUtils.createUser(`skill-other-${Date.now()}@example.com`)).id
  })

  test("returns the managed bot catalog in published order", async () => {
    const created = await createBot(
      { name: "Skill Host", username: `skillhost${Date.now()}bot` },
      { currentSessionId: defaultTestContext.sessionId, currentUserId: creatorUserId },
    )
    const botUserId = Number(created.bot?.id)
    if (!botUserId) throw new Error("Expected bot")

    await BotSkillsModel.replaceForBotUserId(botUserId, [
      { key: "analysis", name: "Data Analysis", description: "Analyze data", sortOrder: 20 },
      { key: "research", name: "Research", sortOrder: 10 },
    ])

    await expect(
      getBotSkills(
        { botUserId: BigInt(botUserId) },
        { currentUserId: otherUserId },
      ),
    ).rejects.toThrow()

    expect(
      await getBotSkills(
        { botUserId: BigInt(botUserId) },
        { currentUserId: creatorUserId },
      ),
    ).toEqual({
      skills: [
        { key: "research", name: "Research", sortOrder: 10 },
        { key: "analysis", name: "Data Analysis", description: "Analyze data", sortOrder: 20 },
      ],
    })
  })
})
