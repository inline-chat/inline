import { beforeEach, describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db, schema } from "../../db"
import { handler } from "../../methods/updateProfilePhoto"
import { FileTypes } from "../../modules/files/types"
import { InlineError } from "../../types/errors"
import { setupTestLifecycle, testUtils } from "../setup"

describe("updateProfilePhoto", () => {
  setupTestLifecycle()

  let user: schema.DbUser
  let otherUser: schema.DbUser
  let otherPhoto: schema.DbFile

  beforeEach(async () => {
    user = await testUtils.createUser("profile-photo@example.test")
    otherUser = await testUtils.createUser("foreign-profile-photo@example.test")
    await db.update(schema.users).set({ firstName: "Original Name", lastName: "Original Suffix" }).where(eq(schema.users.id, user.id))
    await db.update(schema.users).set({ firstName: "Other Name" }).where(eq(schema.users.id, otherUser.id))
    const photo = await createFile(user.id, FileTypes.PHOTO, "existing-photo")
    otherPhoto = await createFile(otherUser.id, FileTypes.PHOTO, "other-photo")
    await handler({ fileUniqueId: photo.fileUniqueId }, { currentUserId: user.id })
    await handler({ fileUniqueId: otherPhoto.fileUniqueId }, { currentUserId: otherUser.id })
  })

  test("accepts an owned legacy photo without a photo graph or type-prefixed handle", async () => {
    const photo = await createFile(user.id, FileTypes.PHOTO, "legacy-human-photo")
    const result = await handler({ fileUniqueId: photo.fileUniqueId }, { currentUserId: user.id })

    expect(result.user.id).toBe(user.id)
    expect(result.user.firstName).toBe("Original Name")
    expect(await storedProfile(user.id)).toEqual({
      firstName: "Original Name", lastName: "Original Suffix", photoFileId: photo.id,
    })
    expect((await storedProfile(otherUser.id)).photoFileId).toBe(otherPhoto.id)
  })

  for (const fileType of [FileTypes.DOCUMENT, FileTypes.VIDEO, null]) {
    test(`rejects an owned ${fileType ?? "untyped"} file without changing either user's profile`, async () => {
      // Stored media kind is authoritative even with a photo-like ID and image MIME.
      const invalid = await createFile(user.id, fileType, `INP-invalid-${fileType ?? "untyped"}`)
      await expectUnchangedRejection(invalid.fileUniqueId)
    })
  }

  test("rejects another user's valid photo without changing either profile", async () => {
    await expectUnchangedRejection(otherPhoto.fileUniqueId)
  })

  test("rejects a missing file without changing either profile", async () => {
    await expectUnchangedRejection("INP-nonexistent-file")
  })

  test("keeps the existing empty-handle rejection instead of clearing the photo", async () => {
    await expectUnchangedRejection("")
  })

  async function expectUnchangedRejection(fileUniqueId: string) {
    const before = await Promise.all([storedProfile(user.id), storedProfile(otherUser.id)])
    let rejection: unknown
    try { await handler({ fileUniqueId }, { currentUserId: user.id }) } catch (error) { rejection = error }
    expect(await Promise.all([storedProfile(user.id), storedProfile(otherUser.id)])).toEqual(before)
    expect(rejection).toBeInstanceOf(InlineError)
    expect(rejection).toMatchObject({ type: "FILE_NOT_FOUND", code: 400 })
  }
})

async function createFile(userId: number, fileType: typeof schema.files.$inferInsert["fileType"], label: string) {
  const [file] = await db.insert(schema.files).values({
    fileUniqueId: `${label}-${userId}`, userId, fileType, mimeType: "image/png", fileSize: 123,
  }).returning()
  if (!file) throw new Error("Failed to create profile file")
  return file
}

async function storedProfile(userId: number) {
  const [user] = await db.select({
    firstName: schema.users.firstName, lastName: schema.users.lastName, photoFileId: schema.users.photoFileId,
  }).from(schema.users).where(eq(schema.users.id, userId)).limit(1)
  if (!user) throw new Error("User profile missing")
  return user
}
