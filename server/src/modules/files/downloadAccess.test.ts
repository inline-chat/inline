import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { GetFilePartInput, RpcError_Code } from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { blockContentImageJobs, blockContents, chatParticipants, documents, files, members, messages, messageAttachments, photos, photoSizes, spaces, urlPreview } from "@in/server/db/schema"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { resolveDownloadFile } from "./downloadAccess"
import { NativeDownloadOperations } from "./downloads"
import { encrypt } from "@in/server/modules/encryption/encryption"
import type { HandlerContext } from "@in/server/realtime/types"

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

  test.each(["V2", "V3"] as const)("%s byte requests require the recipient's exact message and recheck revoked access within 60 seconds", async (carrier) => {
    const owner = await testUtils.createUser("byte-download-owner@example.test")
    const recipient = await testUtils.createUser("byte-download-recipient@example.test")
    const stranger = await testUtils.createUser("byte-download-stranger@example.test")
    const chat = await testUtils.createChat(null, "Byte download", "thread", false, owner.id)
    await testUtils.addParticipant(chat!.id, recipient.id)
    const path = encrypt("native-download-test.bin")
    const [file] = await db.insert(files).values({
      fileUniqueId: "IND_byte_authorization", userId: owner.id, fileSize: 4,
      pathEncrypted: path.encrypted, pathIv: path.iv, pathTag: path.authTag,
    }).returning()
    const [document] = await db.insert(documents).values({ fileId: file!.id }).returning()
    await db.insert(messages).values({ messageId: 1, chatId: chat!.id, fromId: owner.id, documentId: document!.id })
    let reads = 0
    let now = 0
    const operations = new NativeDownloadOperations(resolveDownloadFile, async () => {
      reads += 1
      return new Uint8Array([1, 2, 3, 4])
    }, 25_000, { now: () => now })
    const contextFor = (userId: number): HandlerContext => ({
      userId, sessionId: 1, connectionId: "byte-authorization-test", sendRaw() {}, sendRpcReply() {},
      ...(carrier === "V3" ? { inlineProtocol: { permanentAuthKeyId: new Uint8Array(8) } } : {}),
    })
    const request = GetFilePartInput.create({
      fileUniqueId: file!.fileUniqueId, limit: 4, message: { chatId: BigInt(chat!.id), messageId: 1n },
    })
    expect((await operations.getPart(request, contextFor(owner.id))).data.length).toBe(4)
    expect((await operations.getPart(request, contextFor(recipient.id))).data.length).toBe(4)
    for (const [input, userId] of [
      [request, stranger.id],
      [{ ...request, message: undefined }, recipient.id],
      [{ ...request, message: { ...request.message!, messageId: 2n } }, recipient.id],
    ] as const) {
      await expect(operations.getPart(input, contextFor(userId))).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    }
    expect(reads).toBe(2)
    await db.delete(chatParticipants).where(eq(chatParticipants.chatId, chat!.id))
    AccessGuardsCache.resetChatParticipant(chat!.id, recipient.id)
    now = 59_999
    expect((await operations.getPart(request, contextFor(recipient.id))).data.length).toBe(4)
    now = 60_000
    await expect(operations.getPart(request, contextFor(recipient.id))).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    expect(reads).toBe(3)
  })

  test.each(["message", "space"] as const)("cached bytes recheck a deleted %s within the nonsliding lifetime", async (revocation) => {
    const owner = await testUtils.createUser("expired-download-owner@example.test")
    const recipient = await testUtils.createUser("expired-download-recipient@example.test")
    const space = revocation === "space" ? await testUtils.createSpace("Expired download space") : undefined
    const chat = await testUtils.createChat(space?.id ?? null, "Expired download", "thread", Boolean(space), owner.id)
    if (space) {
      await db.insert(members).values([
        { spaceId: space.id, userId: owner.id, role: "owner" },
        { spaceId: space.id, userId: recipient.id, role: "member" },
      ])
    } else await testUtils.addParticipant(chat!.id, recipient.id)
    const path = encrypt("expired-download-test.bin")
    const [file] = await db.insert(files).values({
      fileUniqueId: "IND_expired_reference", userId: owner.id, fileSize: 4,
      pathEncrypted: path.encrypted, pathIv: path.iv, pathTag: path.authTag,
    }).returning()
    const [document] = await db.insert(documents).values({ fileId: file!.id }).returning()
    const [message] = await db.insert(messages).values({
      messageId: 1, chatId: chat!.id, fromId: owner.id, documentId: document!.id,
    }).returning()
    let now = 0
    let lookups = 0
    let reads = 0
    const operations = new NativeDownloadOperations(async (...args) => {
      lookups += 1
      return resolveDownloadFile(...args)
    }, async (_path, _offset, length) => { reads += 1; return new Uint8Array(length).fill(7) },
    25_000, { now: () => now })
    const context: HandlerContext = {
      userId: recipient.id, sessionId: 1, connectionId: "expired-byte-authorization", sendRaw() {}, sendRpcReply() {},
    }
    const request = GetFilePartInput.create({
      fileUniqueId: file!.fileUniqueId, limit: 4, message: { chatId: BigInt(chat!.id), messageId: 1n },
    })
    await operations.getPart(request, context)
    await operations.getPart({ ...request, limit: 2 }, context)
    expect(lookups).toBe(1)
    if (space) await db.update(spaces).set({ deleted: new Date() }).where(eq(spaces.id, space.id))
    else await db.delete(messages).where(eq(messages.globalId, message!.globalId))
    now = 59_999
    await operations.getPart(request, context)
    await expect(operations.getPart(request, { ...context, sessionId: 2 })).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    expect(lookups).toBe(2)
    now = 60_000
    await expect(operations.getPart(request, context)).rejects.toMatchObject({ code: RpcError_Code.BAD_REQUEST })
    expect(lookups).toBe(3)
    // One read-ahead window served every admitted range within the authorization lifetime.
    expect(reads).toBe(1)
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

  test("rejects a cached member after the containing space is soft-deleted", async () => {
    const owner = await testUtils.createUser("download-deleted-space-owner@example.com")
    const recipient = await testUtils.createUser("download-deleted-space-recipient@example.com")
    const space = await testUtils.createSpace("Deleted download space")
    const chat = await testUtils.createChat(space!.id, "Deleted download", "thread", true, owner.id)
    await db.insert(members).values([
      { spaceId: space!.id, userId: owner.id, role: "owner" },
      { spaceId: space!.id, userId: recipient.id, role: "member" },
    ])
    const [file] = await db.insert(files).values({ fileUniqueId: "IND_deleted_space", userId: owner.id }).returning()
    const [document] = await db.insert(documents).values({ fileId: file!.id }).returning()
    await db.insert(messages).values({ messageId: 1, chatId: chat!.id, fromId: owner.id, documentId: document!.id })
    const locator = { chatId: BigInt(chat!.id), messageId: 1n }

    expect((await resolveDownloadFile(file!.fileUniqueId, recipient.id, locator))?.id).toBe(file!.id)
    await db.update(spaces).set({ deleted: new Date() }).where(eq(spaces.id, space!.id))
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
