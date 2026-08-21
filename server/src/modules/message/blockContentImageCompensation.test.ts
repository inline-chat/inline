import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import {
  blockContentImageJobs,
  blockContents,
  files,
  photos,
  photoSizes,
} from "@in/server/db/schema"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { createFileObjectIdentity } from "@in/server/modules/files/uploadAFile"
import { FILES_PATH_PREFIX } from "@in/server/modules/files/path"
import { FileTypes } from "@in/server/modules/files/types"
import {
  cleanupSettledBlockImageUploadAfterLeaseLossForTests,
  compensateClaimedBlockImageJobForTests,
} from "./blockContentImageWorker"
import { encryptStoredBlockContent } from "./blockContentPayload"

describe("block content image media compensation", () => {
  setupTestLifecycle()

  test("deletes the exact staged object and complete private photo graph", async () => {
    const fixture = await createStagedPhotoFixture("current-lease")
    const deleted: string[] = []

    expect(await compensateClaimedBlockImageJobForTests(
      { ...fixture.job, leaseToken: "current-lease" },
      async (path) => { deleted.push(path) },
    )).toBe(true)

    expect(deleted).toEqual([`${FILES_PATH_PREFIX}/${fixture.identity.path}`])
    expect(await db.select().from(files).where(eq(files.id, fixture.fileId))).toEqual([])
    expect(await db.select().from(photos).where(eq(photos.id, fixture.photoId))).toEqual([])
    expect(await db.select().from(photoSizes).where(eq(photoSizes.fileId, fixture.fileId))).toEqual([])
    const [job] = await db.select().from(blockContentImageJobs)
      .where(eq(blockContentImageJobs.id, fixture.job.id))
    expect(job?.state).toBe("canceled")
    expect(job?.photoId).toBeNull()
    expect(job?.stagedObjectPathEncrypted).toBeNull()
  })

  test("a stale lease cannot delete media adopted by a replacement worker", async () => {
    const fixture = await createStagedPhotoFixture("replacement-lease")
    let deletes = 0

    expect(await compensateClaimedBlockImageJobForTests(
      { ...fixture.job, leaseToken: "stale-lease" },
      async () => { deletes += 1 },
    )).toBe(false)

    expect(deletes).toBe(0)
    expect(await db.select().from(files).where(eq(files.id, fixture.fileId))).toHaveLength(1)
    expect(await db.select().from(photos).where(eq(photos.id, fixture.photoId))).toHaveLength(1)
    const [job] = await db.select().from(blockContentImageJobs)
      .where(eq(blockContentImageJobs.id, fixture.job.id))
    expect(job?.leaseToken).toBe("replacement-lease")
    expect(job?.stagedObjectPathEncrypted).not.toBeNull()
  })

  test("object deletion failure rolls back DB cleanup for durable retry", async () => {
    const fixture = await createStagedPhotoFixture("current-lease")

    await expect(compensateClaimedBlockImageJobForTests(
      { ...fixture.job, leaseToken: "current-lease" },
      async () => { throw new Error("storage unavailable") },
    )).rejects.toThrow("storage unavailable")

    expect(await db.select().from(files).where(eq(files.id, fixture.fileId))).toHaveLength(1)
    expect(await db.select().from(photos).where(eq(photos.id, fixture.photoId))).toHaveLength(1)
    expect(await db.select().from(photoSizes).where(eq(photoSizes.fileId, fixture.fileId))).toHaveLength(1)
    const [job] = await db.select().from(blockContentImageJobs)
      .where(eq(blockContentImageJobs.id, fixture.job.id))
    expect(job?.state).toBe("processing")
    expect(job?.photoId).toBe(fixture.photoId)
    expect(job?.stagedObjectPathEncrypted).not.toBeNull()
  })

  test("a stale writer cleans a late PUT only after the durable job is canceled", async () => {
    const fixture = await createStagedPhotoFixture("lost-lease")
    const staleWriter = { ...fixture.job }
    await db.update(blockContentImageJobs).set({
      state: "canceled",
      leaseToken: null,
      leaseUntil: null,
      stagedObjectPathEncrypted: null,
      stagedObjectPathIv: null,
      stagedObjectPathTag: null,
      photoId: null,
    }).where(eq(blockContentImageJobs.id, fixture.job.id))
    const deleted: string[] = []

    expect(await cleanupSettledBlockImageUploadAfterLeaseLossForTests(
      staleWriter,
      async (path) => { deleted.push(path) },
    )).toBe(true)

    expect(deleted).toEqual([`${FILES_PATH_PREFIX}/${fixture.identity.path}`])
    expect(await db.select().from(files).where(eq(files.id, fixture.fileId))).toEqual([])
    expect(await db.select().from(photos).where(eq(photos.id, fixture.photoId))).toEqual([])
  })
})

async function createStagedPhotoFixture(leaseToken: string) {
  const user = await testUtils.createUser(`rich-image-compensation-${crypto.randomUUID()}@example.com`)
  const identity = createFileObjectIdentity(FileTypes.PHOTO, "png")
  const encryptedPath = encrypt(identity.path)
  const encryptedName = encrypt("remote-image.png")
  const source = encrypt("https://images.example.test/photo.png")
  const stored = encryptStoredBlockContent({
    text: "image",
    blockContent: {
      blocks: [{
        kind: {
          oneofKind: "image",
          image: {
            alt: { offset: 0n, length: 5n },
            state: { oneofKind: "pending", pending: {} },
          },
        },
      }],
    },
  })
  const [content] = await db.insert(blockContents).values({
    payloadEncrypted: stored.encrypted,
    payloadIv: stored.iv,
    payloadTag: stored.authTag,
    revision: 1,
  }).returning()
  if (!content) throw new Error("Failed to create block content fixture")

  const [file] = await db.insert(files).values({
    fileUniqueId: identity.fileUniqueId,
    userId: user.id,
    pathEncrypted: encryptedPath.encrypted,
    pathIv: encryptedPath.iv,
    pathTag: encryptedPath.authTag,
    nameEncrypted: encryptedName.encrypted,
    nameIv: encryptedName.iv,
    nameTag: encryptedName.authTag,
    fileType: FileTypes.PHOTO,
    fileSize: 128,
    mimeType: "image/png",
    width: 16,
    height: 12,
  }).returning()
  if (!file) throw new Error("Failed to create file fixture")

  const [photo] = await db.insert(photos).values({
    format: "png",
    width: 16,
    height: 12,
  }).returning()
  if (!photo) throw new Error("Failed to create photo fixture")
  await db.insert(photoSizes).values({
    fileId: file.id,
    photoId: photo.id,
    size: "f",
    width: 16,
    height: 12,
  })

  const staged = encrypt(identity.path)
  const [job] = await db.insert(blockContentImageJobs).values({
    contentId: content.id,
    expectedRevision: 1,
    blockPath: [0],
    sourceHash: Buffer.alloc(32, 1),
    sourceEncrypted: source.encrypted,
    sourceIv: source.iv,
    sourceTag: source.authTag,
    state: "processing",
    leaseToken,
    leaseUntil: new Date(Date.now() + 60_000),
    stagedObjectPathEncrypted: staged.encrypted,
    stagedObjectPathIv: staged.iv,
    stagedObjectPathTag: staged.authTag,
    photoId: photo.id,
  }).returning()
  if (!job) throw new Error("Failed to create image job fixture")

  return { identity, fileId: file.id, photoId: photo.id, job }
}
