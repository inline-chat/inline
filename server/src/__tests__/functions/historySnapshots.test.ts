import { expect, spyOn, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import { waitForPostCommitHooks } from "@in/server/db/commitHooks"
import { applicationBackgroundWork } from "@in/server/lifecycle/backgroundWork"
import { lockAttachmentChat, refreshAttachmentMembership } from "@in/server/modules/message/attachmentMembership"
import { queueMessageThreadLinkMaterialization } from "@in/server/modules/threadGraph"
import * as threadLinks from "@in/server/modules/threadGraph/links"
import {
  chats,
  documents,
  files,
  messageAttachments,
  messages,
  photoSizes,
  urlPreview,
  updates,
  threadGraphLinks,
} from "@in/server/db/schema"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"
import { getMessages } from "@in/server/functions/messages.getMessages"
import { getChat } from "@in/server/functions/messages.getChat"
import { searchMessages } from "@in/server/functions/messages.searchMessages"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { deleteMessageAttachment } from "@in/server/functions/messages.deleteMessageAttachment"
import { handler as legacySend } from "@in/server/methods/sendMessage"
import { handler as legacyDelete } from "@in/server/methods/deleteMessage"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { encryptMessage, encryptMessageEntities } from "@in/server/modules/encryption/encryptMessage"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { MessageEntities, MessageEntity_Type, SearchMessagesFilter } from "@inline-chat/protocol/core"
import { and, asc, eq, sql } from "drizzle-orm"

setupTestLifecycle()

async function fixture() {
  const user = await testUtils.createUser("history-owner@example.test")
  const peer = await testUtils.createUser("history-peer@example.test")
  const chat = await testUtils.createPrivateChat(user, peer)
  if (!chat) throw new Error("Missing chat")
  const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chat.id) } } }
  return { user, peer, chat, peerId, context: testUtils.functionContext({ userId: user.id }) }
}

for (const readKind of ["history", "resources", "lookup", "text", "chat"] as const) {
  test(`${readKind} roots, preview sidecars and seq share one snapshot during a concurrent edit`, async () => {
    const { user, chat, peerId, context } = await fixture()
    const message = await testUtils.createTestMessage({
      messageId: 1,
      chatId: chat.id,
      fromId: user.id,
      text: "original",
    })
    const oldTitle = encryptMessage("old preview")
    const [preview] = await db
      .insert(urlPreview)
      .values({ title: oldTitle.encrypted, titleIv: oldTitle.iv, titleTag: oldTitle.authTag })
      .returning()
    if (!preview) throw new Error("Missing preview")
    await db.insert(messageAttachments).values({ messageId: message.globalId, urlPreviewId: BigInt(preview.id) })
    await db.update(chats).set({ updateSeq: 7, lastMsgId: 1, messageIdCounter: 1 }).where(eq(chats.id, chat.id))

    const ensureAccess = AccessGuards.ensureChatAccess
    let edited = false
    const guard = spyOn(AccessGuards, "ensureChatAccess").mockImplementation(async (accessChat, userId, tx) => {
      await ensureAccess(accessChat, userId, tx)
      if (!tx || accessChat.id !== chat.id || edited) return
      edited = true
      const newTitle = encryptMessage("new preview")
      await db.transaction(async (writer) => {
        await writer
          .update(urlPreview)
          .set({ title: newTitle.encrypted, titleIv: newTitle.iv, titleTag: newTitle.authTag })
          .where(eq(urlPreview.id, preview.id))
        const changedText = encryptMessage("changed")
        await writer
          .update(messages)
          .set({
            text: null,
            textEncrypted: changedText.encrypted,
            textIv: changedText.iv,
            textTag: changedText.authTag,
            rev: 1,
          })
          .where(eq(messages.globalId, message.globalId))
        await writer.update(chats).set({ updateSeq: 8 }).where(eq(chats.id, chat.id))
      })
    })
    try {
      const result =
        readKind === "history"
          ? await getChatHistory({ peerId }, context)
          : readKind === "resources"
          ? await searchMessages({ peerId, queries: [], filter: SearchMessagesFilter.FILTER_LINKS }, context)
          : readKind === "lookup"
          ? await getMessages({ peerId, messageIds: [1n] }, context)
          : readKind === "text"
          ? await searchMessages({ peerId, queries: ["original"] }, context)
          : await getChat({ peerId, includeRecentMessages: true }, context)
      expect(edited).toBe(true)
      expect(BigInt("seq" in result ? result.seq : result.chat.seq ?? 0)).toBe(7n)
      expect(result.messages.map((row) => row.message)).toEqual(["original"])
      const attachment = result.messages[0]?.attachments?.attachments[0]?.attachment
      expect(attachment?.oneofKind).toBe("urlPreview")
      if (attachment?.oneofKind === "urlPreview") expect(attachment.urlPreview.title).toBe("old preview")
      const next = await getMessages({ peerId, messageIds: [1n] }, context)
      expect(next.seq).toBe(8n)
      expect(next.messages[0]?.message).toBe("changed")
    } finally {
      guard.mockRestore()
    }
  })
}

test("unsupported historical file rows stay readable and are omitted before resource paging", async () => {
  const { user, chat, peerId, context } = await fixture()
  await db.insert(files).values([
    { id: 41, userId: user.id, fileUniqueId: "modern-photo", fileType: "photo", mimeType: "image/jpeg" },
    { id: 42, userId: user.id, fileUniqueId: "legacy-photo", fileType: "photo", mimeType: "image/jpeg" },
  ])
  await db.execute(sql`INSERT INTO photos (id, format) OVERRIDING SYSTEM VALUE VALUES (42, 'jpeg')`)
  await db.insert(photoSizes).values({ photoId: 42, fileId: 41, size: "f" })
  await db.insert(messages).values([
    { chatId: chat.id, fromId: user.id, messageId: 1, fileId: 42 },
    { chatId: chat.id, fromId: user.id, messageId: 2, photoId: 42 },
    { chatId: chat.id, fromId: user.id, messageId: 3, photoId: 42, isSticker: true },
    { chatId: chat.id, fromId: user.id, messageId: 4, text: "recent text" },
  ])
  const history = await getChatHistory({ peerId }, context)
  expect(history.messages.map((row) => row.id)).toEqual([4n, 3n, 2n, 1n])
  expect((await getMessages({ peerId, messageIds: [1n] }, context)).messages.map((row) => row.id)).toEqual([1n])
  const page = await searchMessages(
    { peerId, queries: [], filter: SearchMessagesFilter.FILTER_PHOTO_VIDEO, limit: 2 },
    context,
  )
  expect(page.messages.map((row) => row.id)).toEqual([2n])
  expect(page.messages[0]?.media?.media.oneofKind).toBe("photo")
  expect(page.messages[0]?.media?.media.oneofKind === "photo" && page.messages[0].media.media.photo.photo?.id).toBe(42n)
  expect(
    (
      await searchMessages(
        { peerId, queries: [], filter: SearchMessagesFilter.FILTER_PHOTO_VIDEO, limit: 2, offsetId: 2n },
        context,
      )
    ).messages,
  ).toEqual([])
  expect((await db.select().from(messages).where(eq(messages.messageId, 1)))[0]?.fileId).toBe(42)
})

test("nullable legacy link flags cannot make a short candidate page look exhausted", async () => {
  const { user, chat, peerId, context } = await fixture()
  const entities = MessageEntities.toBinary({
    entities: [{ type: MessageEntity_Type.URL, offset: 0n, length: 18n, entity: { oneofKind: undefined } }],
  })
  const encrypted = encryptMessageEntities(entities)
  await db.insert(messages).values([
    {
      chatId: chat.id,
      fromId: user.id,
      messageId: 1,
      text: "https://inline.chat",
      entitiesEncrypted: encrypted.encrypted,
      entitiesIv: encrypted.iv,
      entitiesTag: encrypted.authTag,
    },
    { chatId: chat.id, fromId: user.id, messageId: 2, text: "plain" },
    { chatId: chat.id, fromId: user.id, messageId: 3, text: "plain" },
  ])
  // A broken sidecar on an unrelated non-link must not break the Links page.
  const [unrelatedDocument] = await db.insert(documents).values({ fileId: null }).returning()
  if (!unrelatedDocument) throw new Error("Missing unrelated document")
  await db
    .update(messages)
    .set({ documentId: unrelatedDocument.id })
    .where(and(eq(messages.chatId, chat.id), eq(messages.messageId, 2)))
  const result = await searchMessages(
    { peerId, queries: [], filter: SearchMessagesFilter.FILTER_LINKS, limit: 1 },
    context,
  )
  expect(result.messages.map((row) => row.id)).toEqual([1n])
  expect(result.messages[0]?.hasLink).toBe(true)
  expect(
    (
      await searchMessages({ peerId, queries: ["inline"], filter: SearchMessagesFilter.FILTER_LINKS }, context)
    ).messages.map((row) => row.id),
  ).toEqual([1n])
})

test("initial attachments roll back with the message and durable seq if their reference is invalid", async () => {
  const { chat, peerId, context } = await fixture()
  await expect(
    sendMessage({ peerId, message: "must not commit", messageAttachments: [{ urlPreviewId: 999_999n }] }, context),
  ).rejects.toThrow()
  expect(await db.select().from(messages).where(eq(messages.chatId, chat.id))).toHaveLength(0)
  expect(
    await db
      .select()
      .from(updates)
      .where(and(eq(updates.entityId, chat.id), eq(updates.bucket, UpdateBucket.Chat))),
  ).toHaveLength(0)
  expect((await getChatHistory({ peerId }, context)).seq).toBe(0n)
})

test("preview removal advances revision and seq and removes preview-only link membership", async () => {
  const { user, chat, peerId, context } = await fixture()
  const message = await testUtils.createTestMessage({
    messageId: 1,
    chatId: chat.id,
    fromId: user.id,
    text: "plain",
  })
  await db.update(messages).set({ hasLink: true }).where(eq(messages.globalId, message.globalId))
  const [preview] = await db.insert(urlPreview).values({}).returning()
  if (!preview) throw new Error("Missing preview")
  const [attachment] = await db
    .insert(messageAttachments)
    .values({ messageId: message.globalId, urlPreviewId: BigInt(preview.id) })
    .returning()
  if (!attachment) throw new Error("Missing attachment")
  await deleteMessageAttachment({ peerId, messageId: 1n, attachmentId: BigInt(attachment.id) }, context)
  const result = await getMessages({ peerId, messageIds: [1n] }, context)
  expect(result.seq).toBe(1n)
  expect(result.messages[0]?.rev).toBe(1n)
  expect(result.messages[0]?.hasLink).toBe(false)
  expect(
    (await searchMessages({ peerId, queries: [], filter: SearchMessagesFilter.FILTER_LINKS }, context)).messages,
  ).toEqual([])
})

test("retained V1 send and delete participate in canonical durable chat sequencing", async () => {
  const { user, peer, chat } = await fixture()
  const context = { currentUserId: user.id, currentSessionId: 1, ip: "127.0.0.1" }
  const sent = await legacySend({ peerUserId: peer.id, text: "legacy hello", parseMarkdown: false }, context)
  const rows = await db.select().from(messages).where(eq(messages.chatId, chat.id))
  expect(sent.message).toBeDefined()
  expect(rows).toHaveLength(1)
  await legacyDelete({ chatId: chat.id, peerUserId: peer.id, messageId: rows[0]!.messageId }, context)
  const durable = await db
    .select()
    .from(updates)
    .where(and(eq(updates.entityId, chat.id), eq(updates.bucket, UpdateBucket.Chat)))
    .orderBy(asc(updates.seq))
  expect(durable.map((row) => row.seq)).toEqual([1, 2])
  expect(durable.map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)).toEqual([
    "newMessage",
    "deleteMessages",
  ])
  expect(await db.select().from(messages).where(eq(messages.chatId, chat.id))).toHaveLength(0)
})

test("released old Apple duplicate older cursors remain compatible", async () => {
  const { user, chat, peerId, context } = await fixture()
  await testUtils.createTestMessage({ chatId: chat.id, fromId: user.id, messageId: 1, text: "old client" })
  expect(
    (await getChatHistory({ peerId, mode: "older", offsetId: 2n, beforeId: 2n }, context)).messages.map(
      (row) => row.id,
    ),
  ).toEqual([1n])
})

test("public exports, large exact lookups and Rust lookahead retain their requested totals", async () => {
  const { user, chat, peerId, context } = await fixture()
  const text = encryptMessage("lookahead page")
  await db.insert(messages).values(
    Array.from({ length: 501 }, (_, index) => ({
      chatId: chat.id,
      fromId: user.id,
      messageId: index + 1,
      textEncrypted: text.encrypted,
      textIv: text.iv,
      textTag: text.authTag,
    })),
  )
  await db.update(chats).set({ updateSeq: 7, lastMsgId: 501, messageIdCounter: 501 }).where(eq(chats.id, chat.id))

  for (const limit of [101, 500, 501]) {
    for (const cursor of [{}, { offsetId: 502n }, { mode: "newer" as const, afterId: 1n }]) {
      const result = await getChatHistory({ peerId, limit, ...cursor }, context)
      const newest = "afterId" in cursor ? Math.min(limit + 1, 501) : 501
      const count = "afterId" in cursor ? Math.min(limit, 500) : limit
      expect(result.messages.map((row) => row.id)).toEqual(
        Array.from({ length: count }, (_, index) => BigInt(newest - index)),
      )
      expect(result.seq).toBe(7n)
    }
  }
  const messageIds = Array.from({ length: 501 }, (_, index) => BigInt(index + 1))
  const lookup = await getMessages({ peerId, messageIds }, context)
  expect(lookup.messages.map((row) => row.id)).toEqual(messageIds)
  expect(lookup.seq).toBe(7n)
  const search = await searchMessages({ peerId, queries: ["lookahead page"], limit: 500 }, context)
  expect(search.messages).toHaveLength(500)
  expect(search.seq).toBe(7n)
})

test("history RPCs reject invalid IDs, unbounded/fractional limits and contradictory cursors before creating a DM", async () => {
  const user = await testUtils.createUser("validation-owner@example.test")
  const peer = await testUtils.createUser("validation-peer@example.test")
  const context = testUtils.functionContext({ userId: user.id })
  const peerId = { type: { oneofKind: "user" as const, user: { userId: BigInt(peer.id) } } }
  for (const offsetId of [-1n, 0n, 2_147_483_648n, 9_007_199_254_740_993n]) {
    await expect(getChatHistory({ peerId, offsetId }, context)).rejects.toThrow()
    await expect(
      searchMessages({ peerId, queries: [], filter: SearchMessagesFilter.FILTER_DOCUMENTS, offsetId }, context),
    ).rejects.toThrow()
    await expect(getMessages({ peerId, messageIds: [offsetId] }, context)).rejects.toThrow()
  }
  for (const limit of [0, -1, 1.5, 2_147_483_648, Infinity, NaN]) {
    await expect(getChatHistory({ peerId, limit }, context)).rejects.toThrow()
    await expect(
      searchMessages({ peerId, queries: [], filter: SearchMessagesFilter.FILTER_DOCUMENTS, limit }, context),
    ).rejects.toThrow()
  }
  await expect(getChatHistory({ peerId, mode: "older", beforeId: 3n, offsetId: 2n }, context)).rejects.toThrow()
  await expect(
    getChatHistory({ peerId, mode: "around", anchorId: 2n, beforeLimit: 2_147_483_647, afterLimit: 1 }, context),
  ).rejects.toThrow()
  await expect(
    searchMessages({ peerId, queries: ["text"], filter: 999 as SearchMessagesFilter }, context),
  ).rejects.toThrow()
  expect(await db.select().from(chats)).toHaveLength(0)
})

test("complete target lookup fails atomically on an incomplete required media sidecar", async () => {
  const { user, chat, peerId, context } = await fixture()
  await testUtils.createTestMessage({ chatId: chat.id, fromId: user.id, messageId: 1, text: "valid" })
  const [document] = await db.insert(documents).values({ fileId: null }).returning()
  if (!document) throw new Error("Missing document")
  await db.insert(messages).values({ chatId: chat.id, fromId: user.id, messageId: 2, documentId: document.id })
  await expect(getMessages({ peerId, messageIds: [1n, 2n, 3n] }, context)).rejects.toThrow()
  const [file] = await db
    .insert(files)
    .values({ userId: user.id, fileUniqueId: "fixed-sidecar", fileType: "document" })
    .returning()
  if (!file) throw new Error("Missing file")
  await db.update(documents).set({ fileId: file.id }).where(eq(documents.id, document.id))
  const complete = await getMessages({ peerId, messageIds: [1n, 2n, 3n] }, context)
  expect(complete.messages.map((row) => row.id)).toEqual([1n, 2n])
  expect(complete.seq).toBe(0n)
})

test("new V1 file shares reuse genuine canonical assets and cannot collide with file identities", async () => {
  const { user, peer, chat, peerId, context } = await fixture()
  await db.insert(files).values([
    { id: 41, userId: user.id, fileUniqueId: "modern-file", fileType: "photo", mimeType: "image/jpeg" },
    { id: 42, userId: user.id, fileUniqueId: "new-v1-file", fileType: "photo", mimeType: "image/jpeg" },
  ])
  await db.execute(sql`INSERT INTO photos (id, format) OVERRIDING SYSTEM VALUE VALUES (42, 'jpeg')`)
  await db.execute(sql`SELECT setval(pg_get_serial_sequence('photos', 'id'), 42, true)`)
  await db.insert(photoSizes).values({ photoId: 42, fileId: 41, size: "f" })
  const legacyContext = { currentUserId: user.id, currentSessionId: 1, ip: "127.0.0.1" }
  await legacySend({ peerUserId: peer.id, fileUniqueId: "new-v1-file" }, legacyContext)
  await legacySend({ peerUserId: peer.id, fileUniqueId: "new-v1-file" }, legacyContext)
  const rows = await db.select().from(messages).where(eq(messages.chatId, chat.id)).orderBy(asc(messages.messageId))
  expect(rows.map((row) => row.photoId)).toEqual([43, 43])
  // V1 JSON still carries its file identity; resource membership uses photoId.
  expect(rows.map((row) => row.fileId)).toEqual([42, 42])
  const page = await getChatHistory({ peerId }, context)
  expect(page.seq).toBe(2n)
  expect(page.messages.map((row) => row.id)).toEqual([2n, 1n])
  expect(
    page.messages.map((row) => (row.media?.media.oneofKind === "photo" ? row.media.media.photo.photo?.id : undefined)),
  ).toEqual([43n, 43n])
})

test("attachment enrichment cannot stale an initial thread-link materialization before its row exists", async () => {
  const { space, users } = await testUtils.createSpaceWithMembers("Enriched graph", ["enriched-graph@example.test"])
  const user = users[0]!
  const source = await testUtils.createChat(space.id, "Source", "thread", true, user.id)
  const target = await testUtils.createChat(space.id, "Target", "thread", true, user.id)
  if (!source || !target) throw new Error("Missing graph chats")
  const entities: MessageEntities = {
    entities: [
      {
        type: MessageEntity_Type.THREAD,
        offset: 0n,
        length: 6n,
        entity: { oneofKind: "thread", thread: { chatId: BigInt(target.id) } },
      },
    ],
  }
  const message = await testUtils.createTestMessage({
    chatId: source.id,
    fromId: user.id,
    messageId: 1,
    text: "Target",
    entities,
  })
  const started = Promise.withResolvers<void>()
  const release = Promise.withResolvers<void>()
  const replaceLinks = threadLinks.replaceMessageThreadLinks
  const materializer = spyOn(threadLinks, "replaceMessageThreadLinks").mockImplementation(async (input) => {
    if (input.sourceMessageGlobalId === message.globalId && input.sourceMessageRevision === 0) {
      started.resolve()
      await release.promise
    }
    return replaceLinks(input)
  })
  try {
    queueMessageThreadLinkMaterialization({
      sourceChat: source,
      sourceChatId: source.id,
      sourceMessageGlobalId: message.globalId,
      sourceMessageId: message.messageId,
      sourceMessageFromId: user.id,
      sourceMessageRevision: 0,
      entities,
    })
    await started.promise
    expect(await db.select().from(threadGraphLinks)).toHaveLength(0)
    await db.transaction(async (tx) => {
      await lockAttachmentChat(tx, source.id)
      await refreshAttachmentMembership(tx, message)
    })
    release.resolve()
    await waitForPostCommitHooks()
    await applicationBackgroundWork.waitForIdle()
    const links = await db
      .select()
      .from(threadGraphLinks)
      .where(
        and(
          eq(threadGraphLinks.kind, "thread_link"),
          eq(threadGraphLinks.fromMessageGlobalId, message.globalId),
          eq(threadGraphLinks.toChatId, target.id),
        ),
      )
    expect(links).toHaveLength(1)
    expect(links[0]?.fromMessageRevision).toBe(1)
    expect(links[0]?.backlinkMessageGlobalId).not.toBeNull()
  } finally {
    release.resolve()
    await waitForPostCommitHooks()
    await applicationBackgroundWork.waitForIdle()
    materializer.mockRestore()
  }
})
