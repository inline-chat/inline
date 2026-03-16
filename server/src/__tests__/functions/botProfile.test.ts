import { beforeEach, describe, expect, test } from "bun:test"
import { setupTestLifecycle, defaultTestContext, testUtils } from "../setup"
import type { FunctionContext } from "../../functions/_types"
import { createBot } from "../../functions/createBot"
import { listBots } from "../../functions/bot.listBots"
import { updateBotProfile } from "../../functions/bot.updateProfile"
import { db, schema } from "../../db"
import { getFileByUniqueId } from "../../db/models/files"
import { eq } from "drizzle-orm"

describe("bot profile", () => {
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

  test("updateBotProfile updates bot name for creator", async () => {
    const created = await createBot({ name: "Old Name", username: "oldnamebot" }, creatorContext)

    const updated = await updateBotProfile(
      { botUserId: created.bot?.id ?? 0n, name: "New Bot Name" },
      creatorContext,
    )

    expect(updated.bot).toBeDefined()
    expect(updated.bot?.firstName).toBe("New Bot Name")

    const listed = await listBots({}, creatorContext)
    expect(listed.bots.some((b) => b.id === (created.bot?.id ?? 0n) && b.firstName === "New Bot Name")).toBe(true)
  })

  test("updateBotProfile rejects non-creator", async () => {
    const created = await createBot({ name: "Private Bot", username: "privateprofilebot" }, creatorContext)

    await expect(
      updateBotProfile({ botUserId: created.bot?.id ?? 0n, name: "Nope" }, otherContext),
    ).rejects.toThrow()
  })

  test("updateBotProfile allows the bot itself to update its own name", async () => {
    const created = await createBot({ name: "Self Edit Bot", username: "selfeditbot" }, creatorContext)
    const botContext: FunctionContext = {
      currentSessionId: defaultTestContext.sessionId,
      currentUserId: Number(created.bot?.id ?? 0n),
    }

    const updated = await updateBotProfile(
      { botUserId: created.bot?.id ?? 0n, name: "Bot Self Renamed" },
      botContext,
    )

    expect(updated.bot?.firstName).toBe("Bot Self Renamed")
  })

  test("updateBotProfile allows the bot itself to update its own photo", async () => {
    const created = await createBot({ name: "Photo Bot", username: "photobotselfbot" }, creatorContext)
    const botUserId = Number(created.bot?.id ?? 0n)
    const botContext: FunctionContext = {
      currentSessionId: defaultTestContext.sessionId,
      currentUserId: botUserId,
    }

    const [file] = await db
      .insert(schema.files)
      .values({
        fileUniqueId: `bot-photo-${botUserId}`,
        userId: botUserId,
        fileType: "photo",
        mimeType: "image/png",
        fileSize: 123,
      })
      .returning()

    if (!file) throw new Error("Failed to create bot-owned file")

    const lookedUp = await getFileByUniqueId(file.fileUniqueId)
    expect(lookedUp?.userId).toBe(botUserId)

    const updated = await updateBotProfile(
      { botUserId: BigInt(botUserId), photoFileUniqueId: file.fileUniqueId },
      botContext,
    )

    const [storedBot] = await db
      .select({ photoFileId: schema.users.photoFileId })
      .from(schema.users)
      .where(eq(schema.users.id, botUserId))
      .limit(1)

    expect(updated.bot?.id).toBe(BigInt(botUserId))
    expect(storedBot?.photoFileId).toBe(file.id)
  })
})
