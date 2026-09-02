import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { MessageModel } from "@in/server/db/models/messages"
import { db } from "@in/server/db"
import {
  blockContentImageJobs,
  blockContents,
  files,
  messages,
  photos,
  photoSizes,
} from "@in/server/db/schema"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { encryptBinary } from "@in/server/modules/encryption/encryption"
import { parseBlockContent } from "@in/server/modules/message/blockContent"
import {
  deleteUnreferencedBlockContents,
  prepareBlockContent,
} from "@in/server/modules/message/blockContentStorage"
import { parseMarkdown } from "@in/server/modules/message/parseMarkdown"
import { encodeFullMessage } from "@in/server/realtime/encoders/encodeMessage"
import { and, eq } from "drizzle-orm"
import {
  BlockTable_Alignment,
  MessageEntities,
  Photo_Format,
  type BlockContent,
} from "@inline-chat/protocol/core"
import { setupTestDatabase, teardownTestDatabase, testUtils } from "../setup"

describe("message block content storage", () => {
  let userId: number
  let chatId: number

  beforeAll(async () => {
    await setupTestDatabase()
    const user = await testUtils.createUser("block-content-storage@example.com")
    const chat = await testUtils.createTestChat()
    userId = user.id
    chatId = chat.id
  })
  afterAll(teardownTestDatabase)

  test("ordinary message reads preserve tables written under the historical cell limit", async () => {
    const blockContent: BlockContent = {
      blocks: [{
        kind: {
          oneofKind: "table",
          table: {
            alignments: Array.from({ length: 16 }, () => BlockTable_Alignment.LEFT),
            rows: Array.from({ length: 256 }, () => ({
              cells: Array.from({ length: 16 }, () => ({ offset: 0n, length: 1n })),
            })),
          },
        },
      }],
    }
    // Insert the persisted shape directly: new Markdown is still limited to 256 cells.
    const rich = prepareBlockContent({
      text: "x",
      parsed: { blockContent, imageSources: [] },
    })
    if (!rich) throw new Error("Expected prepared historical content")
    const inserted = await MessageModel.insertMessage({
      chatId,
      fromId: userId,
      date: new Date(),
      ...encryptedFields("x", undefined),
    }, rich)
    expect(inserted.message.blockContent).toEqual(blockContent)

    const fetched = await MessageModel.getMessage(inserted.message.messageId, chatId)
    expect(fetched.blockContent).toEqual(blockContent)
  })

  test("atomically inserts, decodes, reuses, replaces, and clears canonical content", async () => {
    const first = prepared("# Result\n\n![one](https://example.com/one.png){width=640 height=480}")
    const inserted = await MessageModel.insertMessage({
      chatId,
      fromId: userId,
      date: new Date(),
      ...encryptedFields(first.text, first.prepared.entities),
    }, first.prepared)

    const contentId = inserted.message.blockContentId
    expect(contentId).toBeTruthy()
    expect(inserted.message.blockContent?.blocks.map((block) => block.kind.oneofKind)).toEqual(["heading", "image"])

    const decoded = await MessageModel.getMessage(inserted.message.messageId, chatId)
    expect(decoded?.blockContent?.blocks.map((block) => block.kind.oneofKind)).toEqual(["heading", "image"])

    let jobs = await db.select().from(blockContentImageJobs).where(eq(blockContentImageJobs.contentId, contentId!))
    expect(jobs).toHaveLength(1)
    const originalJobId = jobs[0]!.id

    const sameImage = prepared(
      "## A much longer updated heading\n\n![new alternative](https://example.com/one.png){width=800 height=400}",
    )
    await MessageModel.editMessage({
      messageId: inserted.message.messageId,
      chatId,
      text: sameImage.text,
      entities: sameImage.prepared.entities,
      blockContent: sameImage.prepared,
    })

    jobs = await db.select().from(blockContentImageJobs).where(eq(blockContentImageJobs.contentId, contentId!))
    expect(jobs).toHaveLength(1)
    expect(jobs[0]?.id).toBe(originalJobId)
    expect(jobs[0]?.expectedRevision).toBe(1)
    expect(jobs[0]?.state).toBe("pending")

    const edited = await MessageModel.getMessage(inserted.message.messageId, chatId)
    const editedImage = edited?.blockContent?.blocks[1]?.kind
    expect(editedImage?.oneofKind).toBe("image")
    if (editedImage?.oneofKind === "image") {
      const alt = editedImage.image.alt
      expect(alt).toBeDefined()
      expect(alt ? sameImage.text.slice(Number(alt.offset), Number(alt.offset + alt.length)) : undefined)
        .toBe("new alternative")
      expect(editedImage.image.state.oneofKind).toBe("pending")
      if (editedImage.image.state.oneofKind === "pending") {
        expect(editedImage.image.state.pending.dimensions).toEqual({ width: 800, height: 400 })
      }
    }

    const changedImage = prepared("## Updated\n\n![two](https://example.com/two.png)")
    await MessageModel.editMessage({
      messageId: inserted.message.messageId,
      chatId,
      text: changedImage.text,
      entities: changedImage.prepared.entities,
      blockContent: changedImage.prepared,
    })

    jobs = await db.select().from(blockContentImageJobs).where(eq(blockContentImageJobs.contentId, contentId!))
    expect(jobs).toHaveLength(2)
    expect(jobs.find((job) => job.id === originalJobId)?.state).toBe("canceled")
    expect(jobs.find((job) => job.id !== originalJobId)?.expectedRevision).toBe(2)

    await MessageModel.editMessage({
      messageId: inserted.message.messageId,
      chatId,
      text: "plain",
      blockContent: null,
    })

    expect(await db.select().from(blockContents).where(eq(blockContents.id, contentId!))).toHaveLength(0)
    expect(await db.select().from(blockContentImageJobs).where(eq(blockContentImageJobs.contentId, contentId!)))
      .toHaveLength(0)
  })

  test("reuses uniquely moved image jobs but fails closed for ambiguous duplicates", async () => {
    const one = "https://example.com/stream-one.png"
    const two = "https://example.com/stream-two.png"
    const initial = prepared(`![one](${one})\n\n![two](${two})`)
    const inserted = await MessageModel.insertMessage({
      chatId,
      fromId: userId,
      date: new Date(),
      ...encryptedFields(initial.text, initial.prepared.entities),
    }, initial.prepared)
    const contentId = inserted.message.blockContentId!
    let jobs = await db.select().from(blockContentImageJobs).where(eq(blockContentImageJobs.contentId, contentId))
    expect(jobs).toHaveLength(2)
    const firstId = jobs.find((job) => job.blockPath.join(".") === "0.0")?.id
    const secondId = jobs.find((job) => job.blockPath.join(".") === "0.1")?.id
    expect(firstId).toBeTruthy()
    expect(secondId).toBeTruthy()

    await db.update(blockContentImageJobs).set({
      state: "processing",
      leaseToken: "moving-image",
      leaseUntil: new Date(Date.now() + 60_000),
    }).where(eq(blockContentImageJobs.id, firstId!))

    const insertedPrefix = prepared(`Introduction\n\n![one](${one})\n\n![two](${two})`)
    await MessageModel.editMessage({
      messageId: inserted.message.messageId,
      chatId,
      text: insertedPrefix.text,
      entities: insertedPrefix.prepared.entities,
      blockContent: insertedPrefix.prepared,
    })
    jobs = await db.select().from(blockContentImageJobs).where(eq(blockContentImageJobs.contentId, contentId))
    expect(jobs).toHaveLength(2)
    expect(jobs.find((job) => job.id === firstId)).toMatchObject({
      blockPath: [1, 0], expectedRevision: 1, state: "processing", leaseToken: "moving-image",
    })
    expect(jobs.find((job) => job.id === secondId)).toMatchObject({
      blockPath: [1, 1], expectedRevision: 1, state: "pending",
    })

    const reordered = prepared(`Introduction\n\n![two](${two})\n\n![one](${one})`)
    await MessageModel.editMessage({
      messageId: inserted.message.messageId,
      chatId,
      text: reordered.text,
      entities: reordered.prepared.entities,
      blockContent: reordered.prepared,
    })
    jobs = await db.select().from(blockContentImageJobs).where(eq(blockContentImageJobs.contentId, contentId))
    expect(jobs).toHaveLength(2)
    expect(jobs.find((job) => job.id === firstId)).toMatchObject({ blockPath: [1, 1], expectedRevision: 2 })
    expect(jobs.find((job) => job.id === secondId)).toMatchObject({ blockPath: [1, 0], expectedRevision: 2 })

    const duplicateUrl = "https://example.com/duplicate.png"
    const duplicate = prepared(`![first](${duplicateUrl})\n\nbetween\n\n![second](${duplicateUrl})`)
    const duplicateMessage = await MessageModel.insertMessage({
      chatId,
      fromId: userId,
      date: new Date(),
      ...encryptedFields(duplicate.text, duplicate.prepared.entities),
    }, duplicate.prepared)
    const duplicateContentId = duplicateMessage.message.blockContentId!
    const shiftedDuplicate = prepared(`prefix\n\n![first](${duplicateUrl})\n\nbetween\n\n![second](${duplicateUrl})`)
    await MessageModel.editMessage({
      messageId: duplicateMessage.message.messageId,
      chatId,
      text: shiftedDuplicate.text,
      entities: shiftedDuplicate.prepared.entities,
      blockContent: shiftedDuplicate.prepared,
    })
    const duplicateJobs = await db.select().from(blockContentImageJobs)
      .where(eq(blockContentImageJobs.contentId, duplicateContentId))
    expect(duplicateJobs).toHaveLength(4)
    expect(duplicateJobs.filter((job) => job.state === "canceled")).toHaveLength(2)
    expect(duplicateJobs.filter((job) => job.state === "pending" && job.expectedRevision === 1)).toHaveLength(2)
  })

  test("retains a shared content row until its last wrapper is deleted", async () => {
    const value = prepared("Shared **content**")
    const owner = await MessageModel.insertMessage({
      chatId,
      fromId: userId,
      date: new Date(),
      ...encryptedFields(value.text, value.prepared.entities),
    }, value.prepared)
    const wrapper = await MessageModel.insertMessage({
      chatId,
      fromId: userId,
      date: new Date(),
      ...encryptedFields(value.text, value.prepared.entities),
    })
    const contentId = owner.message.blockContentId!

    await db
      .update(messages)
      .set({ blockContentId: contentId })
      .where(and(eq(messages.chatId, chatId), eq(messages.messageId, wrapper.message.messageId)))

    await MessageModel.deleteMessages([BigInt(owner.message.messageId)], chatId)
    expect(await db.select().from(blockContents).where(eq(blockContents.id, contentId))).toHaveLength(1)

    await MessageModel.deleteMessages([BigInt(wrapper.message.messageId)], chatId)
    expect(await db.select().from(blockContents).where(eq(blockContents.id, contentId))).toHaveLength(0)
  })

  test("retains an orphan content owner and its active staged-upload lease", async () => {
    const value = prepared("![staged](https://example.com/staged.png)")
    const inserted = await MessageModel.insertMessage({
      chatId,
      fromId: userId,
      date: new Date(),
      ...encryptedFields(value.text, value.prepared.entities),
    }, value.prepared)
    const contentId = inserted.message.blockContentId!
    const staged = encryptBinary(Buffer.from("INP000000000000000000000/staged.png"))
    await db.update(blockContentImageJobs).set({
      state: "processing",
      leaseToken: "old-owner",
      leaseUntil: new Date(Date.now() + 60_000),
      stagedObjectPathEncrypted: staged.encrypted,
      stagedObjectPathIv: staged.iv,
      stagedObjectPathTag: staged.authTag,
    }).where(eq(blockContentImageJobs.contentId, contentId))

    await MessageModel.deleteMessages([BigInt(inserted.message.messageId)], chatId)
    expect(await db.select().from(blockContents).where(eq(blockContents.id, contentId))).toHaveLength(1)
    const [job] = await db.select().from(blockContentImageJobs)
      .where(eq(blockContentImageJobs.contentId, contentId))
    expect(job?.state).toBe("processing")
    expect(job?.leaseToken).toBe("old-owner")

    await db.transaction(async (tx) => {
      await tx.update(blockContentImageJobs).set({
        stagedObjectPathEncrypted: null,
        stagedObjectPathIv: null,
        stagedObjectPathTag: null,
      }).where(eq(blockContentImageJobs.contentId, contentId))
      await deleteUnreferencedBlockContents(tx, [contentId])
    })
    expect(await db.select().from(blockContents).where(eq(blockContents.id, contentId))).toHaveLength(0)
  })

  test("hydrates ready block photos from current rows and preserves missing snapshots", async () => {
    const [file] = await db
      .insert(files)
      .values({
        fileUniqueId: "BLOCK_PHOTO_HYDRATION",
        userId,
        fileSize: 777,
        mimeType: "image/png",
        fileType: "photo",
        width: 640,
        height: 480,
      })
      .returning()
    if (!file) throw new Error("Expected file")

    const [photo] = await db
      .insert(photos)
      .values({ format: "png", width: 640, height: 480 })
      .returning()
    if (!photo) throw new Error("Expected photo")

    await db.insert(photoSizes).values({
      fileId: file.id,
      photoId: photo.id,
      size: "f",
      width: 640,
      height: 480,
    })

    const missingPhotoId = BigInt(photo.id + 1_000_000)
    const blockContent: BlockContent = {
      blocks: [{
        kind: {
          oneofKind: "album",
          album: {
            images: [
              {
                alt: { offset: 0n, length: 0n },
                state: {
                  oneofKind: "ready",
                  ready: {
                    id: BigInt(photo.id),
                    date: 1n,
                    format: Photo_Format.JPEG,
                    sizes: [{
                      type: "f",
                      w: 1,
                      h: 1,
                      size: 1,
                      cdnUrl: "https://expired.invalid/current",
                    }],
                  },
                },
              },
              {
                alt: { offset: 0n, length: 0n },
                state: {
                  oneofKind: "ready",
                  ready: {
                    id: missingPhotoId,
                    date: 2n,
                    format: Photo_Format.JPEG,
                    sizes: [{
                      type: "f",
                      w: 2,
                      h: 2,
                      size: 2,
                      cdnUrl: "https://expired.invalid/missing",
                    }],
                  },
                },
              },
            ],
          },
        },
      }],
    }
    const rich = prepareBlockContent({
      text: "x",
      parsed: { blockContent, imageSources: [] },
    })
    if (!rich) throw new Error("Expected prepared content")

    const inserted = await MessageModel.insertMessage({
      chatId,
      fromId: userId,
      date: new Date(),
      ...encryptedFields("x", undefined),
    }, rich)
    const fetched = await MessageModel.getMessage(inserted.message.messageId, chatId)
    expect(fetched.blockContent?.blocks[0]?.kind.oneofKind).toBe("album")
    expect(fetched.blockContentPhotos?.size).toBe(1)
    expect(fetched.blockContentPhotos?.has(BigInt(photo.id))).toBe(true)

    const encoded = encodeFullMessage({
      message: fetched,
      encodingForUserId: userId,
      encodingForPeer: {
        peer: { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } },
      },
    })
    const album = encoded.blockContent?.blocks[0]
    if (album?.kind.oneofKind !== "album") throw new Error("Expected album")
    const [current, missing] = album.kind.album.images
    expect(current?.state.oneofKind).toBe("ready")
    if (current?.state.oneofKind !== "ready") throw new Error("Expected current photo")
    expect(current.state.ready.format).toBe(Photo_Format.PNG)
    expect(current.state.ready.sizes[0]?.size).toBe(777)
    expect(current.state.ready.sizes[0]?.w).toBe(640)
    expect(missing?.state.oneofKind).toBe("ready")
    if (missing?.state.oneofKind !== "ready") throw new Error("Expected missing fallback")
    expect(missing.state.ready.sizes[0]?.cdnUrl).toBe("https://expired.invalid/missing")

    const storedAlbum = fetched.blockContent?.blocks[0]
    if (storedAlbum?.kind.oneofKind !== "album") throw new Error("Expected stored album")
    const storedCurrent = storedAlbum.kind.album.images[0]
    if (storedCurrent?.state.oneofKind !== "ready") throw new Error("Expected stored ready photo")
    expect(storedCurrent.state.ready.sizes[0]?.cdnUrl).toBe("https://expired.invalid/current")
  })
})

function prepared(markdown: string) {
  const flat = parseMarkdown(markdown)
  const parsed = parseBlockContent(markdown)
  if (!parsed) throw new Error("Expected block content")
  const prepared = prepareBlockContent({
    text: flat.text,
    entities: flat.entities.length > 0 ? { entities: flat.entities } : undefined,
    parsed,
  })
  if (!prepared) throw new Error("Expected prepared block content")
  return { text: flat.text, prepared }
}

function encryptedFields(text: string, entities: MessageEntities | undefined) {
  const encryptedText = encryptMessage(text)
  const entityBytes = entities ? MessageEntities.toBinary(entities) : undefined
  const encryptedEntities = entityBytes && entityBytes.length > 0 ? encryptBinary(entityBytes) : undefined
  return {
    textEncrypted: encryptedText.encrypted,
    textIv: encryptedText.iv,
    textTag: encryptedText.authTag,
    entitiesEncrypted: encryptedEntities?.encrypted ?? null,
    entitiesIv: encryptedEntities?.iv ?? null,
    entitiesTag: encryptedEntities?.authTag ?? null,
  }
}
