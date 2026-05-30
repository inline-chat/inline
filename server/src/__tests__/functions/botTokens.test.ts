import { beforeEach, describe, expect, test } from "bun:test"
import { setupTestLifecycle, defaultTestContext, testUtils } from "../setup"
import type { FunctionContext } from "../../functions/_types"
import { createBot } from "../../functions/createBot"
import { listBots } from "../../functions/bot.listBots"
import { deleteBot } from "../../functions/bot.deleteBot"
import { revealBotToken } from "../../functions/bot.revealToken"
import { rotateBotToken } from "../../functions/bot.rotateToken"
import { getUserIdFromToken } from "../../controllers/plugins"
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

  test("deleteBot soft-deletes bot user and revokes token access", async () => {
    const created = await createBot({ name: "Delete Bot", username: "deletebot" }, creatorContext)
    const botId = created.bot?.id
    if (!botId) throw new Error("Expected created bot")
    const botUserId = Number(botId)

    const deleted = await deleteBot({ botUserId: botId }, creatorContext)

    expect(deleted.botUserId).toBe(botId)

    const [botUser] = await db
      .select()
      .from(schema.users)
      .where(eq(schema.users.id, botUserId))
      .limit(1)

    expect(botUser).toBeDefined()
    expect(botUser?.deleted).toBe(true)

    const listed = await listBots({}, creatorContext)
    expect(listed.bots.some((bot) => bot.id === botId)).toBe(false)

    const [storedToken] = await db
      .select()
      .from(schema.botTokens)
      .where(eq(schema.botTokens.botUserId, botUserId))
      .limit(1)

    expect(storedToken).toBeUndefined()

    const sessions = await db.select().from(schema.sessions).where(eq(schema.sessions.userId, botUserId))
    expect(sessions.length).toBeGreaterThan(0)
    expect(sessions.every((session) => session.revoked !== null)).toBe(true)

    await expect(getUserIdFromToken(created.token)).rejects.toThrow()
    await expect(revealBotToken({ botUserId: botId }, creatorContext)).rejects.toThrow()
    await expect(rotateBotToken({ botUserId: botId }, creatorContext)).rejects.toThrow()
  })

  test("deleteBot rejects non-creator", async () => {
    const created = await createBot({ name: "Private Delete Bot", username: "privatedeletebot" }, creatorContext)

    await expect(deleteBot({ botUserId: created.bot?.id ?? 0n }, otherContext)).rejects.toThrow()
  })
})
