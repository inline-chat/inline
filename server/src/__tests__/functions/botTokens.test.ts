import { beforeEach, describe, expect, test } from "bun:test"
import { setupTestLifecycle, defaultTestContext, testUtils } from "../setup"
import type { FunctionContext } from "../../functions/_types"
import { createBot } from "../../functions/createBot"
import { listBots } from "../../functions/bot.listBots"
import { revealBotToken } from "../../functions/bot.revealToken"
import { rotateBotToken } from "../../functions/bot.rotateToken"
import { db, schema } from "../../db"
import { eq } from "drizzle-orm"

describe("bot tokens", () => {
  setupTestLifecycle()

  let creator: any
  let otherUser: any
  let creatorContext: FunctionContext
  let otherContext: FunctionContext

  beforeEach(async () => {
    creator = await testUtils.createUser("creator@example.com")
    otherUser = await testUtils.createUser("other@example.com")

    creatorContext = {
      currentSessionId: defaultTestContext.sessionId,
      currentUserId: creator.id,
    }

    otherContext = {
      currentSessionId: defaultTestContext.sessionId,
      currentUserId: otherUser.id,
    }
  })

  test("listBots returns bots owned by the creator", async () => {
    await createBot({ name: "Alpha Bot", username: "alphabot" }, creatorContext)
    await createBot({ name: "Beta Bot", username: "betabot" }, creatorContext)

    const result = await listBots({}, creatorContext)

    expect(result.bots.length).toBe(2)
    expect(result.bots[0]?.bot).toBe(true)
  })

  test("revealBotToken returns the stored token", async () => {
    const created = await createBot({ name: "Reveal Bot", username: "revealbot" }, creatorContext)

    const revealed = await revealBotToken({ botUserId: created.bot?.id ?? 0n }, creatorContext)

    expect(revealed.token).toBe(created.token)
  })

  test("revealBotToken rejects non-creator", async () => {
    const created = await createBot({ name: "Private Bot", username: "privatebot" }, creatorContext)

    await expect(revealBotToken({ botUserId: created.bot?.id ?? 0n }, otherContext)).rejects.toThrow()
  })

  test("rotateBotToken returns a new token and revokes the previous session", async () => {
    const created = await createBot({ name: "Rotate Bot", username: "rotatebot" }, creatorContext)
    const botUserId = Number(created.bot?.id ?? 0n)

    const [before] = await db
      .select({ sessionId: schema.botTokens.sessionId })
      .from(schema.botTokens)
      .where(eq(schema.botTokens.botUserId, botUserId))
      .limit(1)

    const rotated = await rotateBotToken({ botUserId: created.bot?.id ?? 0n }, creatorContext)

    expect(rotated.token).toBeDefined()
    expect(rotated.token).not.toBe(created.token)

    const revealed = await revealBotToken({ botUserId: created.bot?.id ?? 0n }, creatorContext)
    expect(revealed.token).toBe(rotated.token)

    if (before?.sessionId) {
      const [oldSession] = await db
        .select()
        .from(schema.sessions)
        .where(eq(schema.sessions.id, before.sessionId))
        .limit(1)

      expect(oldSession?.revoked).not.toBeNull()
    }
  })
})
