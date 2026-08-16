import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { botAgents } from "@in/server/db/schema"
import { BotAgentsModel } from "./botAgents"

describe("BotAgentsModel", () => {
  setupTestLifecycle()

  test("creates a valid name-only Agent with a globally addressable id", async () => {
    const bot = await testUtils.createUser(`agent-name-only-${Date.now()}@example.com`)
    const created = await BotAgentsModel.create({ botUserId: bot.id, name: "  Analyst  " })

    expect(created.name).toBe("Analyst")
    expect(created.skillKey).toBeUndefined()
    expect(created.instructions).toBeUndefined()
    expect(await BotAgentsModel.get(Number(created.id))).toEqual(created)
  })

  test("encrypts custom instructions at rest and decodes them at the model boundary", async () => {
    const bot = await testUtils.createUser(`agent-encrypted-${Date.now()}@example.com`)
    const created = await BotAgentsModel.create({
      botUserId: bot.id,
      name: "Sales",
      skillKey: "sales",
      instructions: "Only use qualified leads.",
    })

    const [row] = await db.select().from(botAgents).where(eq(botAgents.id, Number(created.id))).limit(1)
    expect(row?.instructionsEncrypted).toBeInstanceOf(Buffer)
    expect(row?.instructionsEncrypted?.toString("utf8")).not.toContain("qualified leads")
    expect((await BotAgentsModel.get(Number(created.id)))?.instructions).toBe("Only use qualified leads.")
  })
})
