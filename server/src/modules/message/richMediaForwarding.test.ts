import { describe, expect, test } from "bun:test"
import { type RichBlock, type RichMessage } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { files, photos, photoSizes } from "@in/server/db/schema"
import { cloneRichTextMediaForForward } from "@in/server/modules/message/richMediaForwarding"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../../__tests__/setup"

setupTestLifecycle()

describe("rich media forwarding", () => {
  test("clones duplicate nested internal photo refs once", async () => {
    const sourceOwner = await testUtils.createUser("rich-forward-source@example.com")
    const newOwner = await testUtils.createUser("rich-forward-destination@example.com")
    const sourcePhoto = await createPhotoForUser(sourceOwner.id)

    const cloned = await cloneRichTextMediaForForward(richWithRepeatedPhoto(sourcePhoto.id), newOwner.id)
    const clonedPhotoIds = collectPhotoIds(cloned?.blocks ?? [])

    expect(clonedPhotoIds).toHaveLength(3)
    expect(new Set(clonedPhotoIds).size).toBe(1)
    expect(clonedPhotoIds[0]).not.toBe(sourcePhoto.id)

    const [clonedPhoto] = await db.select().from(photos).where(eq(photos.id, clonedPhotoIds[0]!)).limit(1)
    expect(clonedPhoto?.id).toBe(clonedPhotoIds[0])

    const clonedFiles = await db
      .select({ userId: files.userId })
      .from(photoSizes)
      .innerJoin(files, eq(photoSizes.fileId, files.id))
      .where(eq(photoSizes.photoId, clonedPhotoIds[0]!))

    expect(clonedFiles.map((file) => file.userId)).toEqual([newOwner.id])
  })
})

const createPhotoForUser = async (userId: number) => {
  const [file] = await db
    .insert(files)
    .values({
      fileUniqueId: `RICH-FWD-PHOTO-${userId}`,
      userId,
      fileType: "photo",
      mimeType: "image/jpeg",
      fileSize: 1234,
      width: 320,
      height: 180,
    })
    .returning()

  const [photo] = await db
    .insert(photos)
    .values({
      format: "jpeg",
      width: 320,
      height: 180,
    })
    .returning()

  if (!file || !photo) {
    throw new Error("Failed to create source photo")
  }

  await db.insert(photoSizes).values({
    fileId: file.id,
    photoId: photo.id,
    size: "f",
    width: 320,
    height: 180,
  })

  return photo
}

const richWithRepeatedPhoto = (photoId: number): RichMessage => ({
  version: 1,
  fallbackText: "Repeated photo",
  blocks: [
    photoBlock(photoId, "root-photo"),
    {
      blockId: "quote",
      block: {
        oneofKind: "quote",
        quote: {
          expandable: false,
          initiallyCollapsed: false,
          blocks: [photoBlock(photoId, "quote-photo")],
        },
      },
    },
    {
      blockId: "preview",
      block: {
        oneofKind: "linkPreview",
        linkPreview: {
          url: "https://inline.chat",
          media: mediaRef(photoId, "preview photo"),
          compact: false,
        },
      },
    },
  ],
})

const photoBlock = (photoId: number, blockId: string): RichBlock => ({
  blockId,
  block: {
    oneofKind: "photo",
    photo: {
      media: mediaRef(photoId, "photo"),
      caption: [],
    },
  },
})

const mediaRef = (photoId: number, alt: string) => ({
  alt,
  width: 320,
  height: 180,
  media: { oneofKind: "photoId" as const, photoId: BigInt(photoId) },
})

const collectPhotoIds = (blocks: RichBlock[]): number[] => {
  const ids: number[] = []
  for (const block of blocks) {
    switch (block.block.oneofKind) {
      case "photo":
        if (block.block.photo.media?.media.oneofKind === "photoId") {
          ids.push(Number(block.block.photo.media.media.photoId))
        }
        break
      case "quote":
        ids.push(...collectPhotoIds(block.block.quote.blocks ?? []))
        break
      case "linkPreview":
        if (block.block.linkPreview.media?.media.oneofKind === "photoId") {
          ids.push(Number(block.block.linkPreview.media.media.photoId))
        }
        break
      default:
        break
    }
  }
  return ids
}
