import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { blockContentImageJobs, blockContents, chatParticipants, documents, files, messages, messageAttachments, photos, photoSizes, urlPreview } from "@in/server/db/schema"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { resolveDownloadFile } from "./downloadAccess"

describe("native download authorization", () => {
  setupTestLifecycle()

  test("only the owner can read an unshared file", async () => {
    const owner = await testUtils.createUser("download-owner@example.com")
    const stranger = await testUtils.createUser("download-stranger@example.com")
    const [file] = await db.insert(files).values({ fileUniqueId: "IND_private", userId: owner.id }).returning()
    expect((await resolveDownloadFile("IND_private", owner.id))?.id).toBe(file!.id)
    expect(await resolveDownloadFile("IND_private", stranger.id)).toBeUndefined()
    expect(await resolveDownloadFile("IND_missing", stranger.id)).toBeUndefined()
  })

  test("requires the exact message reference and current chat access for documents and thumbnails", async () => {
    const owner = await testUtils.createUser("download-sender@example.com")
    const recipient = await testUtils.createUser("download-recipient@example.com")
    const chat = await testUtils.createChat(null, "Download", "thread", false, owner.id)
    await testUtils.addParticipant(chat!.id, recipient.id)
    const [file, thumbnail, unrelated] = await db.insert(files).values([
      { fileUniqueId: "IND_shared", userId: owner.id },
      { fileUniqueId: "INP_thumbnail", userId: owner.id },
      { fileUniqueId: "IND_unrelated", userId: owner.id },
    ]).returning()
    const [photo] = await db.insert(photos).values({ format: "jpeg" }).returning()
    await db.insert(photoSizes).values({ photoId: photo!.id, fileId: thumbnail!.id, size: "f" })
    const [document] = await db.insert(documents).values({ fileId: file!.id, photoId: BigInt(photo!.id) }).returning()
    const [message] = await db.insert(messages).values({
      messageId: 1, chatId: chat!.id, fromId: owner.id, documentId: document!.id,
    }).returning()
    const locator = { chatId: BigInt(chat!.id), messageId: 1n }
    expect((await resolveDownloadFile(file!.fileUniqueId, recipient.id, locator))?.id).toBe(file!.id)
    expect((await resolveDownloadFile(thumbnail!.fileUniqueId, recipient.id, locator))?.id).toBe(thumbnail!.id)
    expect(await resolveDownloadFile(unrelated!.fileUniqueId, recipient.id, locator)).toBeUndefined()
    expect(await resolveDownloadFile(file!.fileUniqueId, recipient.id, { ...locator, messageId: 2n })).toBeUndefined()

    await db.delete(chatParticipants).where(eq(chatParticipants.chatId, chat!.id))
    AccessGuardsCache.resetChatParticipant(chat!.id, recipient.id)
    expect(await resolveDownloadFile(file!.fileUniqueId, recipient.id, locator)).toBeUndefined()
    await testUtils.addParticipant(chat!.id, recipient.id)
    AccessGuardsCache.resetChatParticipant(chat!.id, recipient.id)
    await db.delete(messages).where(eq(messages.globalId, message!.globalId))
    expect(await resolveDownloadFile(file!.fileUniqueId, recipient.id, locator)).toBeUndefined()
  })

  test("rich image provenance must belong to the current content revision", async () => {
    const owner = await testUtils.createUser("download-rich-owner@example.com")
    const recipient = await testUtils.createUser("download-rich-recipient@example.com")
    const chat = await testUtils.createChat(null, "Rich download", "thread", false, owner.id)
    await testUtils.addParticipant(chat!.id, recipient.id)
    const [file] = await db.insert(files).values({ fileUniqueId: "INP_rich", userId: owner.id }).returning()
    const [photo] = await db.insert(photos).values({ format: "jpeg" }).returning()
    await db.insert(photoSizes).values({ photoId: photo!.id, fileId: file!.id, size: "f" })
    const [content] = await db.insert(blockContents).values({
      payloadEncrypted: Buffer.from([1]), payloadIv: Buffer.from([2]), payloadTag: Buffer.from([3]),
    }).returning()
    await db.insert(blockContentImageJobs).values({
      contentId: content!.id, expectedRevision: 0, blockPath: [0], sourceHash: Buffer.from([4]),
      sourceEncrypted: Buffer.from([5]), sourceIv: Buffer.from([6]), sourceTag: Buffer.from([7]), state: "ready", photoId: photo!.id,
    })
    await db.insert(messages).values({ messageId: 1, chatId: chat!.id, fromId: owner.id, blockContentId: content!.id })
    const locator = { chatId: BigInt(chat!.id), messageId: 1n }
    expect((await resolveDownloadFile(file!.fileUniqueId, recipient.id, locator))?.id).toBe(file!.id)
    await db.update(blockContents).set({ revision: 1 }).where(eq(blockContents.id, content!.id))
    expect(await resolveDownloadFile(file!.fileUniqueId, recipient.id, locator)).toBeUndefined()
  })

  test("authorizes URL preview media through the exact message attachment", async () => {
    const owner = await testUtils.createUser("preview-owner@example.com")
    const recipient = await testUtils.createUser("preview-recipient@example.com")
    const chat = await testUtils.createChat(null, "Preview download", "thread", false, owner.id)
    await testUtils.addParticipant(chat!.id, recipient.id)
    const [main, author] = await db.insert(files).values([
      { fileUniqueId: "IND_preview", userId: owner.id }, { fileUniqueId: "INP_author", userId: owner.id },
    ]).returning()
    const [document] = await db.insert(documents).values({ fileId: main!.id }).returning()
    const [photo] = await db.insert(photos).values({ format: "jpeg" }).returning()
    await db.insert(photoSizes).values({ photoId: photo!.id, fileId: author!.id, size: "f" })
    const [preview] = await db.insert(urlPreview).values({ documentId: document!.id, authorPhotoId: photo!.id }).returning()
    const [message] = await db.insert(messages).values({ messageId: 17, chatId: chat!.id, fromId: owner.id }).returning()
    const [attachment] = await db.insert(messageAttachments).values({ messageId: message!.globalId, urlPreviewId: BigInt(preview!.id) }).returning()
    const locator = { chatId: BigInt(chat!.id), messageId: 17n }
    expect((await resolveDownloadFile(main!.fileUniqueId, recipient.id, locator))?.id).toBe(main!.id)
    expect((await resolveDownloadFile(author!.fileUniqueId, recipient.id, locator))?.id).toBe(author!.id)
    await db.delete(messageAttachments).where(eq(messageAttachments.id, attachment!.id))
    expect(await resolveDownloadFile(main!.fileUniqueId, recipient.id, locator)).toBeUndefined()
  })
})
