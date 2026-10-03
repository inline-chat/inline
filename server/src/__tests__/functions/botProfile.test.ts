import { beforeEach, describe, expect, test } from "bun:test"
import { setupTestLifecycle, defaultTestContext, testUtils } from "../setup"
import type { FunctionContext } from "../../functions/_types"
import { createBot } from "../../functions/createBot"
import { listBots } from "../../functions/bot.listBots"
import { updateBotProfile } from "../../functions/bot.updateProfile"
import { db, schema } from "../../db"
import { getFileByUniqueId } from "../../db/models/files"
import { FileTypes } from "../../modules/files/types"
import { RealtimeRpcError } from "../../realtime/errors"
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

  test("updateBotProfile stores the complete bot name in firstName and clears legacy lastName", async () => {
    const created = await createBot({ name: "Mo's", username: "legacynamebot" }, creatorContext)
    const botUserId = Number(created.bot?.id ?? 0n)
    await db.update(schema.users).set({ lastName: "Codex" }).where(eq(schema.users.id, botUserId))

    const updated = await updateBotProfile(
      { botUserId: BigInt(botUserId), name: "Mo's Codex" },
      creatorContext,
    )
    const [stored] = await db
      .select({ firstName: schema.users.firstName, lastName: schema.users.lastName })
      .from(schema.users)
      .where(eq(schema.users.id, botUserId))
      .limit(1)

    expect(updated.bot?.firstName).toBe("Mo's Codex")
    expect(stored).toEqual({ firstName: "Mo's Codex", lastName: null })
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

  test("updateBotProfile accepts a creator-owned legacy photo without a photo graph or type-prefixed ID", async () => {
    const created = await createBot({ name: "Creator Photo Bot", username: "creatorphotobot" }, creatorContext)
    const botUserId = Number(created.bot?.id ?? 0n)
    const file = await createProfileFile(creator.id, FileTypes.PHOTO, "legacy-profile-photo")

    const updated = await updateBotProfile(
      { botUserId: BigInt(botUserId), name: " Updated Photo Bot ", photoFileUniqueId: ` ${file.fileUniqueId} ` },
      creatorContext,
    )

    expect(updated.bot?.firstName).toBe("Updated Photo Bot")
    expect(await storedProfile(botUserId)).toEqual({
      firstName: "Updated Photo Bot", lastName: null, photoFileId: file.id,
    })
  })

  for (const actor of ["creator", "bot"] as const) {
    for (const fileType of [FileTypes.DOCUMENT, FileTypes.VIDEO]) {
      test(`updateBotProfile rejects a ${actor}-owned ${fileType} without changing the name or photo`, async () => {
        const created = await createBot({ name: "Original Bot", username: `reject${actor}${fileType}bot` }, creatorContext)
        const botUserId = Number(created.bot?.id ?? 0n)
        const context = actor === "creator" ? creatorContext : { ...creatorContext, currentUserId: botUserId }
        const photo = await createProfileFile(context.currentUserId, FileTypes.PHOTO, `existing-${actor}-${fileType}`)
        await updateBotProfile({ botUserId: BigInt(botUserId), photoFileUniqueId: photo.fileUniqueId }, context)
        await db.update(schema.users).set({ lastName: "Legacy Suffix" }).where(eq(schema.users.id, botUserId))
        const before = await storedProfile(botUserId)
        // An image MIME type and photo-like handle do not make a stored document/video a photo.
        const invalid = await createProfileFile(context.currentUserId, fileType, `INP-invalid-${actor}-${fileType}`)

        await expectUnchangedRejection(
          botUserId, before,
          () => updateBotProfile({ botUserId: BigInt(botUserId), name: "Unwanted Rename", photoFileUniqueId: invalid.fileUniqueId }, context),
          RealtimeRpcError.Code.BAD_REQUEST,
        )
      })
    }

    test(`updateBotProfile rejects a foreign photo for the ${actor} without changing either field`, async () => {
      const created = await createBot({ name: "Original Bot", username: `foreign${actor}photobot` }, creatorContext)
      const botUserId = Number(created.bot?.id ?? 0n)
      const context = actor === "creator" ? creatorContext : { ...creatorContext, currentUserId: botUserId }
      const photo = await createProfileFile(context.currentUserId, FileTypes.PHOTO, `owned-${actor}`)
      await updateBotProfile({ botUserId: BigInt(botUserId), photoFileUniqueId: photo.fileUniqueId }, context)
      // A creator-owned upload is still foreign to a bot acting as itself.
      const foreign = await createProfileFile(actor === "bot" ? creator.id : otherUser.id, FileTypes.PHOTO, `foreign-${actor}`)

      await expectUnchangedRejection(
        botUserId, await storedProfile(botUserId),
        () => updateBotProfile({ botUserId: BigInt(botUserId), name: "Unwanted Rename", photoFileUniqueId: foreign.fileUniqueId }, context),
        RealtimeRpcError.Code.BAD_REQUEST,
      )
    })
  }

  for (const unknown of [false, true]) {
    test(`updateBotProfile rejects ${unknown ? "an untyped owned" : "a missing"} file without changing either field`, async () => {
      const created = await createBot({ name: "Original Bot", username: unknown ? "untypedphotobot" : "missingphotobot" }, creatorContext)
      const botUserId = Number(created.bot?.id ?? 0n)
      const photo = await createProfileFile(creator.id, FileTypes.PHOTO, "existing-photo")
      await updateBotProfile({ botUserId: BigInt(botUserId), photoFileUniqueId: photo.fileUniqueId }, creatorContext)
      const invalidId = unknown
        ? (await createProfileFile(creator.id, null, "INP-untyped-file")).fileUniqueId
        : "INP-nonexistent-file"

      await expectUnchangedRejection(
        botUserId, await storedProfile(botUserId),
        () => updateBotProfile({ botUserId: BigInt(botUserId), name: "Unwanted Rename", photoFileUniqueId: invalidId }, creatorContext),
        RealtimeRpcError.Code.BAD_REQUEST,
      )
    })
  }

  test("updateBotProfile preserves a photo on name-only and no-op saves", async () => {
    const created = await createBot({ name: "Original Bot", username: "noopsavebot" }, creatorContext)
    const botUserId = Number(created.bot?.id ?? 0n)
    const photo = await createProfileFile(creator.id, FileTypes.PHOTO, "no-op-photo")
    await updateBotProfile({ botUserId: BigInt(botUserId), photoFileUniqueId: photo.fileUniqueId }, creatorContext)
    const renamed = await updateBotProfile({ botUserId: BigInt(botUserId), name: "Renamed Bot" }, creatorContext)
    const noOp = await updateBotProfile({ botUserId: BigInt(botUserId) }, creatorContext)

    expect(renamed.bot?.firstName).toBe("Renamed Bot")
    expect(noOp.bot?.firstName).toBe("Renamed Bot")
    expect(await storedProfile(botUserId)).toEqual({ firstName: "Renamed Bot", lastName: null, photoFileId: photo.id })
  })

  test("updateBotProfile rejects an unrelated caller even with its own valid photo", async () => {
    const created = await createBot({ name: "Original Bot", username: "deniedphotobot" }, creatorContext)
    const botUserId = Number(created.bot?.id ?? 0n)
    const photo = await createProfileFile(creator.id, FileTypes.PHOTO, "creator-photo")
    await updateBotProfile({ botUserId: BigInt(botUserId), photoFileUniqueId: photo.fileUniqueId }, creatorContext)
    const otherPhoto = await createProfileFile(otherUser.id, FileTypes.PHOTO, "other-photo")

    await expectUnchangedRejection(
      botUserId, await storedProfile(botUserId),
      () => updateBotProfile({ botUserId: BigInt(botUserId), name: "Unwanted Rename", photoFileUniqueId: otherPhoto.fileUniqueId }, otherContext),
      RealtimeRpcError.Code.USER_ID_INVALID,
    )
  })

  test("updateBotProfile clears a bot profile photo for its creator", async () => {
    const created = await createBot({ name: "Clear Photo Bot", username: "clearphotobot" }, creatorContext)
    const botUserId = Number(created.bot?.id ?? 0n)
    const [file] = await db
      .insert(schema.files)
      .values({
        fileUniqueId: `creator-bot-photo-${botUserId}`,
        userId: creator.id,
        fileType: "photo",
        mimeType: "image/png",
        fileSize: 123,
      })
      .returning()

    if (!file) throw new Error("Failed to create creator-owned file")

    await updateBotProfile(
      { botUserId: BigInt(botUserId), photoFileUniqueId: file.fileUniqueId },
      creatorContext,
    )
    const cleared = await updateBotProfile(
      { botUserId: BigInt(botUserId), photoFileUniqueId: "" },
      creatorContext,
    )

    const [storedBot] = await db
      .select({ photoFileId: schema.users.photoFileId })
      .from(schema.users)
      .where(eq(schema.users.id, botUserId))
      .limit(1)

    expect(storedBot?.photoFileId).toBeNull()
    expect(cleared.bot?.profilePhoto).toBeUndefined()
  })
})

async function createProfileFile(userId: number, fileType: typeof schema.files.$inferInsert["fileType"], label: string) {
  const [file] = await db.insert(schema.files).values({
    fileUniqueId: `${label}-${userId}`, userId, fileType, mimeType: "image/png", fileSize: 123,
  }).returning()
  if (!file) throw new Error("Failed to create profile file")
  return file
}

async function storedProfile(botUserId: number) {
  const [bot] = await db.select({
    firstName: schema.users.firstName, lastName: schema.users.lastName, photoFileId: schema.users.photoFileId,
  }).from(schema.users).where(eq(schema.users.id, botUserId)).limit(1)
  if (!bot) throw new Error("Bot profile missing")
  return bot
}

async function expectUnchangedRejection(
  botUserId: number,
  before: Awaited<ReturnType<typeof storedProfile>>,
  update: () => Promise<unknown>,
  code: RealtimeRpcError["code"],
) {
  let rejection: unknown
  try { await update() } catch (error) { rejection = error }
  // Check persisted state even if the invalid request unexpectedly succeeds.
  expect(await storedProfile(botUserId)).toEqual(before)
  expect(rejection).toBeInstanceOf(RealtimeRpcError)
  expect(rejection).toMatchObject({ code })
}
