import { afterAll, beforeAll, describe, expect, spyOn, test } from "bun:test"
import { randomBytes, randomUUID } from "node:crypto"
import { and, eq, sql } from "drizzle-orm"
import {
  GlobalSearchExcerpt_Field,
  Method,
  RpcCall,
  RpcResult,
  type SearchMessagesGlobalInput,
} from "@inline-chat/protocol/core"
import { READ_ONLY_RPC_METHODS, TRANSFER_RPC_METHODS } from "@inline-chat/protocol/transfers"
import type { Transaction } from "@in/server/db/types"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { deleteMessage } from "@in/server/functions/messages.deleteMessage"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { ensureChatSearchKey } from "@in/server/modules/search/cloudCrypto"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { insertGridTranscriptMessage } from "@in/server/modules/grid/transcription/messages"
import {
  bootstrapSearchDocuments,
  requeueObsoleteSearchDocuments,
  runCloudSearchIndexBatch,
} from "@in/server/modules/search/cloudIndex"
import { CloudSearchWorker, HISTORY_BATCH, historyPauseMs } from "@in/server/modules/search/cloudWorker"
import { handleRpcCall } from "@in/server/realtime/handlers/_rpc"
import type { HandlerContext } from "@in/server/realtime/types"
import { setupTestLifecycle, testUtils } from "../setup"

async function caller(userId: number): Promise<HandlerContext> {
  const { session } = await testUtils.createSessionForUser(userId, { clientType: "macos" })
  const authKeyId = randomBytes(8)
  await db.insert(schema.inlineProtocolAuthKeys).values({
    authKeyId,
    userId,
    accountSessionId: session.id,
    authorizedAt: new Date(),
    authKeyEncrypted: randomBytes(284),
    currentServerSalt: 1n,
    keyEncryptionKeyId: "test",
  })
  return {
    userId,
    sessionId: session.id,
    connectionId: randomUUID(),
    isBot: false,
    inlineProtocol: { permanentAuthKeyId: authKeyId },
    sendRaw() {},
    sendRpcReply() {},
  }
}

async function search(ctx: HandlerContext, query: string, options: Partial<SearchMessagesGlobalInput> = {}) {
  const call = RpcCall.fromBinary(
    RpcCall.toBinary({
      method: Method.SEARCH_MESSAGES_GLOBAL,
      input: { oneofKind: "searchMessagesGlobal", searchMessagesGlobal: { query, ...options } },
    }),
  )
  const result = RpcResult.fromBinary(
    RpcResult.toBinary({ reqMsgId: 1n, result: await handleRpcCall(call, ctx) }),
  ).result
  if (result.oneofKind !== "searchMessagesGlobal") throw Error("Expected global message search result")
  return result.searchMessagesGlobal
}

async function fixture() {
  const user = await testUtils.createUser()
  const chat = (await testUtils.createPrivateChat(user, user))!
  const ctx = await caller(user.id)
  const peer = { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chat.id) } } }
  const actor = { currentUserId: user.id, currentSessionId: ctx.sessionId }
  return { user, chat, ctx, peer, actor }
}

function filename(value: string) {
  const { encrypted, iv, authTag } = encrypt(value)
  return { fileName: encrypted, fileNameIv: iv, fileNameTag: authTag }
}

async function drain() {
  const stats = await runCloudSearchIndexBatch({ limit: 100 })
  expect(stats.failed).toBe(0)
  return stats
}

describe("global message search RPC", () => {
  setupTestLifecycle()
  const previous = process.env["CLOUD_MESSAGE_SEARCH_ENABLED"]
  beforeAll(async () => {
    await db.execute(sql`select inline_search_set_capture(true)`)
    process.env["CLOUD_MESSAGE_SEARCH_ENABLED"] = "true"
  })
  afterAll(() => {
    if (previous === undefined) delete process.env["CLOUD_MESSAGE_SEARCH_ENABLED"]
    else process.env["CLOUD_MESSAGE_SEARCH_ENABLED"] = previous
  })

  test("captionless filenames, Arabic keyboard variants, highlighting and isolated chat keys", async () => {
    const { user, chat, ctx } = await fixture()
    const outsider = await testUtils.createUser("outside@example.test")
    const hidden = (await testUtils.createPrivateChat(outsider, outsider))!
    const [doc] = await db.insert(schema.documents).values(filename("Release_Plan-v2_تقرير_۲۰۲۶.pdf")).returning()
    for (const [chatId, fromId] of [
      [chat.id, user.id],
      [hidden.id, outsider.id],
    ] as const) {
      await db
        .insert(schema.messages)
        .values({ chatId, fromId, messageId: 1, mediaType: "document", documentId: doc!.id })
    }
    expect((await search(ctx, "plan")).indexIncomplete).toBe(true)
    await drain()
    for (const query of ["plan", "v2", "PDF", '"release plan"', "تَقْرِير ٢٠٢٦"]) {
      const page = await search(ctx, query)
      expect(page.indexIncomplete).toBe(false)
      expect(page.hits.map((hit) => hit.chatId)).toEqual([BigInt(chat.id)])
      expect(page.hits[0]!.excerpts[0]!.field).toBe(GlobalSearchExcerpt_Field.DOCUMENT_FILENAME)
    }
    const excerpt = (await search(ctx, "2026")).hits[0]!.excerpts[0]!
    const range = excerpt.highlights[0]!
    expect(excerpt.text.slice(range.offset, range.offset + range.length)).toBe("۲۰۲۶")
    for (const miss of ["pla", "lease", "plans", '"plan release"']) expect((await search(ctx, miss)).hits).toEqual([])
    await expect(search(ctx, "pla*")).rejects.toMatchObject({
      codeNumber: 400,
      publicReason: expect.stringContaining("whole words"),
    })
    const projections = await db.select().from(schema.messageSearchDocuments)
    expect(projections).toHaveLength(2)
    expect(projections[0]!.tags).toHaveLength(6)
    expect(projections[0]!.tags.some((tag) => projections[1]!.tags.includes(tag))).toBe(false)
    const [width] = await db.execute<{ bytes: number }>(
      sql`select pg_column_size(tags[1]) as bytes from message_search_documents limit 1`,
    )
    expect(width!.bytes).toBe(16)
    await db.update(schema.documents).set(filename("Amended.docx")).where(eq(schema.documents.id, doc!.id))
    expect((await search(ctx, "plan")).hits).toEqual([])
    expect((await drain()).indexed).toBe(2)
    expect((await search(ctx, "amended")).hits).toHaveLength(1)
  })

  test("real send, concurrent edit, deletion and stale-worker retry", async () => {
    const { chat, ctx, actor, peer } = await fixture()
    await sendMessage({ peerId: peer, message: "approved release", skipLinkProcessing: true }, actor)
    const [row] = await db.select().from(schema.messages).where(eq(schema.messages.chatId, chat.id))
    const messageId = BigInt(row!.messageId)
    const raced = await runCloudSearchIndexBatch({
      beforePublish: async () => {
        await editMessage({ peer, messageId, text: "final report", parseMarkdown: false }, actor)
      },
    })
    expect(raced.superseded).toBe(1)
    await drain()
    expect((await search(ctx, "approved")).hits).toEqual([])
    expect((await search(ctx, '"final report"')).hits.map((hit) => hit.messageId)).toEqual([messageId])
    expect((await search(ctx, '"report final"')).hits).toEqual([])
    await editMessage({ peer, messageId, text: "third edit", parseMarkdown: false }, actor)
    const deleted = await runCloudSearchIndexBatch({
      beforePublish: async () => {
        await deleteMessage({ peer, messageIds: [messageId] }, actor)
      },
    })
    expect(deleted.superseded).toBe(1)
    expect(await db.select().from(schema.messageSearchDocuments)).toHaveLength(0)
    expect((await search(ctx, "third")).hits).toEqual([])
  })

  test("stable cross-chat pagination, cursor binding, cleared history and revoked sessions", async () => {
    const { user, chat, ctx } = await fixture()
    const teammate = await testUtils.createUser("teammate@example.test")
    const second = (await testUtils.createPrivateChat(user, teammate))!
    const timestamp = new Date()
    for (let i = 1; i <= 4; i++) {
      for (const c of [chat, second])
        await db.insert(schema.messages).values({
          chatId: c.id,
          fromId: user.id,
          messageId: i,
          text: "legacy needle",
          date: timestamp,
        })
    }
    await drain()
    const first = await search(ctx, "needle", { limit: 3 })
    const next = await search(ctx, "needle", { limit: 5, cursor: first.nextCursor! })
    const actual = [...first.hits, ...next.hits].map((h) => [Number(h.chatId), Number(h.messageId)])
    expect(actual).toEqual(
      [4, 3, 2, 1].flatMap((i) => [
        [second.id, i],
        [chat.id, i],
      ]),
    )
    expect(next.nextCursor).toBeUndefined()
    await expect(search(ctx, "other", { cursor: first.nextCursor })).rejects.toThrow()
    await expect(search(ctx, "needle", { cursor: first.nextCursor + "x" })).rejects.toThrow()
    await expect(search(await caller(teammate.id), "needle", { cursor: first.nextCursor })).rejects.toThrow()
    await db.insert(schema.dialogs).values({ chatId: second.id, userId: user.id, collapsedMaxId: 3 })
    expect(
      (await search(ctx, "needle", { cursor: first.nextCursor })).hits.every((h) => Number(h.chatId) === chat.id),
    ).toBe(true)
    await expect(search(ctx, "needle", { cursor: first.nextCursor, homeOnly: true })).rejects.toThrow()
    await expect(search(await caller(user.id), "needle", { cursor: first.nextCursor })).rejects.toThrow()
    expect(
      (await search(ctx, "needle")).hits.filter((h) => Number(h.chatId) === second.id).map((h) => h.messageId),
    ).toEqual([4n])
    await db.update(schema.sessions).set({ revoked: new Date() }).where(eq(schema.sessions.id, ctx.sessionId))
    await expect(search(ctx, "needle")).rejects.toThrow()
  })

  test("phrase stays within a field and historical backfill resumes at its database checkpoint", async () => {
    const { chat, ctx, user } = await fixture()
    const [doc] = await db.insert(schema.documents).values(filename("Release.pdf")).returning()
    await db.insert(schema.messages).values(
      [1, 2, 3].map((i) => ({
        chatId: chat.id,
        fromId: user.id,
        messageId: i,
        text: "approved",
        documentId: doc!.id,
      })),
    )
    // Reproduce rows from before the migration installed its triggers.
    await db.delete(schema.messageSearchDocuments)
    expect(await bootstrapSearchDocuments(2)).toBe(false)
    expect(await bootstrapSearchDocuments(2)).toBe(true)
    await drain()
    expect((await search(ctx, "release approved")).hits[0]!.excerpts.map((e) => e.field)).toEqual([
      GlobalSearchExcerpt_Field.BODY,
      GlobalSearchExcerpt_Field.DOCUMENT_FILENAME,
    ])
    expect((await search(ctx, '"approved release"')).hits).toEqual([])
    expect(await bootstrapSearchDocuments(2)).toBe(true)
    expect((await drain()).examined).toBe(0)
  })

  test("indexes Grid speech and excludes encrypted structural fallback text", async () => {
    const { user, chat, ctx } = await fixture()
    for (const kind of ["turn", "started"] as const) {
      await db.transaction((tx) =>
        insertGridTranscriptMessage(tx, {
          actorUserId: user.id,
          chatId: chat.id,
          speakerUserId: user.id,
          segmentId: kind,
          runId: randomUUID(),
          kind,
          text: "transcription searchable",
        }),
      )
    }
    await drain()
    expect((await search(ctx, "transcription")).hits.map((h) => h.messageId)).toEqual([1n])
  })

  test("a new DM and a newly provisioned chat key preserve a continuation", async () => {
    const { chat, user, ctx } = await fixture()
    for (let i = 1; i <= 3; i++)
      await testUtils.createTestMessage({ chatId: chat.id, fromId: user.id, messageId: i, text: "needle" })
    await drain()
    const first = await search(ctx, "needle", { limit: 1 })
    const newChat = (await testUtils.createPrivateChat(user, await testUtils.createUser("new@example.test")))!
    const second = await search(ctx, "needle", { limit: 1, cursor: first.nextCursor })
    await ensureChatSearchKey(newChat.id)
    await testUtils.createTestMessage({ chatId: newChat.id, fromId: user.id, messageId: 1, text: "needle" })
    await drain()
    expect((await search(ctx, "needle", { cursor: second.nextCursor })).hits.map((h) => h.messageId)).toEqual([1n])
    await expect(
      db.delete(schema.chatSearchKeys).where(eq(schema.chatSearchKeys.chatId, newChat.id)).execute(),
    ).rejects.toThrow()
    await db.delete(schema.chats).where(eq(schema.chats.id, newChat.id))
    expect((await search(ctx, "needle")).hits).toHaveLength(3)
  })

  test("direct child access, membership loss, bot and transport restrictions", async () => {
    const { ctx, user } = await fixture()
    const owner = await testUtils.createUser("owner@example.test")
    const parent = (await testUtils.createChat(null, "hidden parent", "thread", false, owner.id))!
    const child = (await testUtils.createChat(null, "shared child", "thread", false, owner.id))!
    await db.update(schema.chats).set({ parentChatId: parent.id }).where(eq(schema.chats.id, child.id))
    await testUtils.addParticipant(child.id, user.id)
    for (const c of [parent, child]) {
      for (let i = 1; i <= 2; i++)
        await testUtils.createTestMessage({ chatId: c.id, messageId: i, fromId: owner.id, text: "discovery" })
    }
    await drain()
    const first = await search(ctx, "discovery", { limit: 1 })
    expect(first.hits.map((h) => h.chatId)).toEqual([BigInt(child.id)])
    expect(first.hits[0]!.peer?.type).toEqual({ oneofKind: "chat", chat: { chatId: BigInt(child.id) } })
    await db
      .delete(schema.chatParticipants)
      .where(and(eq(schema.chatParticipants.chatId, child.id), eq(schema.chatParticipants.userId, user.id)))
    expect((await search(ctx, "discovery", { cursor: first.nextCursor })).hits).toEqual([])
    expect((await search(ctx, "discovery")).hits).toEqual([])
    await expect(search({ ...ctx, inlineProtocol: undefined }, "discovery")).rejects.toMatchObject({ codeNumber: 401 })
    await expect(search({ ...ctx, isBot: true }, "discovery")).rejects.toMatchObject({ codeNumber: 403 })
    expect(TRANSFER_RPC_METHODS.has(Method.SEARCH_MESSAGES_GLOBAL)).toBe(false)
    expect(READ_ONLY_RPC_METHODS.has(Method.SEARCH_MESSAGES_GLOBAL)).toBe(true)
  })

  test("typing a newer query supersedes an in-flight RPC on the same session", async () => {
    const { ctx, chat, user } = await fixture()
    await testUtils.createTestMessage({ chatId: chat.id, fromId: user.id, messageId: 1, text: "newer" })
    await drain()
    const entered = Promise.withResolvers<void>(),
      release = Promise.withResolvers<void>()
    let paused = false
    const transaction = db.transaction.bind(db)
    const hook = spyOn(db, "transaction").mockImplementation(
      async <T>(read: (tx: Transaction) => Promise<T>, config?: Parameters<typeof db.transaction>[1]) => {
        const result = await transaction(read, config)
        if (!paused && config?.accessMode === "read only") {
          paused = true
          entered.resolve()
          await release.promise
        }
        return result
      },
    )
    try {
      const old = search(ctx, "older").catch((error) => error)
      await entered.promise
      const newest = search(ctx, "newer")
      expect(await old).toMatchObject({ codeNumber: 408 })
      release.resolve()
      expect((await newest).hits.map((h) => h.messageId)).toEqual([1n])
    } finally {
      release.resolve()
      hook.mockRestore()
    }
  })

  test("a session revoked after verification is checked again before serialization", async () => {
    const { user, chat, ctx } = await fixture()
    await testUtils.createTestMessage({ chatId: chat.id, fromId: user.id, messageId: 1, text: "private hit" })
    await drain()
    const original = db.transaction.bind(db)
    let readSnapshots = 0
    const hook = spyOn(db, "transaction").mockImplementation(
      async <T>(run: (tx: Transaction) => Promise<T>, config?: Parameters<typeof db.transaction>[1]) => {
        const result = await original(run, config)
        if (config?.accessMode === "read only" && ++readSnapshots === 1) {
          await db.update(schema.sessions).set({ revoked: new Date() }).where(eq(schema.sessions.id, ctx.sessionId))
        }
        return result
      },
    )
    try {
      await expect(search(ctx, "private")).rejects.toThrow()
      expect(readSnapshots).toBe(1)
    } finally {
      hook.mockRestore()
    }
  })

  test("revoking the lookahead chat at disclosure refills the page from still-visible history", async () => {
    const { ctx, chat, user } = await fixture()
    const owner = await testUtils.createUser("owner-race@example.test")
    const revoked = (await testUtils.createChat(null, "shared", "thread", false, owner.id))!
    await testUtils.addParticipant(revoked.id, user.id)
    for (const [id, chatId, stamp] of [
      [1, chat.id, 1],
      [1, revoked.id, 2],
      [2, chat.id, 3],
    ] as const) {
      await db
        .insert(schema.messages)
        .values({ chatId, messageId: id, fromId: owner.id, text: "found", date: new Date(stamp * 1000) })
    }
    await drain()
    const transaction = db.transaction.bind(db)
    let revokedAccess = false
    const hook = spyOn(db, "transaction").mockImplementation(
      async <T>(read: (tx: Transaction) => Promise<T>, config?: Parameters<typeof db.transaction>[1]) => {
        const result = await transaction(read, config)
        if (!revokedAccess && config?.accessMode === "read only") {
          revokedAccess = true
          await db
            .delete(schema.chatParticipants)
            .where(and(eq(schema.chatParticipants.chatId, revoked.id), eq(schema.chatParticipants.userId, user.id)))
        }
        return result
      },
    )
    try {
      const first = await search(ctx, "found", { limit: 1 })
      expect(first.hits.map((h) => h.messageId)).toEqual([2n])
      expect(first.nextCursor).toBeDefined()
      const next = await search(ctx, "found", { limit: 1, cursor: first.nextCursor })
      expect(next.hits.map((h) => [h.chatId, h.messageId])).toEqual([[BigInt(chat.id), 1n]])
      expect(next.nextCursor).toBeUndefined()
    } finally {
      hook.mockRestore()
    }
  })

  test("workers take disjoint leases, and an expired claim recovers after a crash", async () => {
    const { user, chat, ctx } = await fixture()
    for (let i = 1; i <= 3; i++)
      await testUtils.createTestMessage({ chatId: chat.id, fromId: user.id, messageId: i, text: "worker" })
    const leases = new Set<bigint>()
    const beforePublish = async (id: bigint) => {
      expect(leases.has(id)).toBe(false)
      leases.add(id)
    }
    const batches = await Promise.all([1, 2].map(() => runCloudSearchIndexBatch({ limit: 1, beforePublish })))
    expect(batches.map((batch) => batch.indexed)).toEqual([1, 1])
    await db
      .update(schema.messageSearchDocuments)
      .set({ claimUntil: new Date(Date.now() + 60_000) })
      .where(eq(schema.messageSearchDocuments.ready, false))
    expect((await drain()).examined).toBe(0)
    await db
      .update(schema.messageSearchDocuments)
      .set({ claimUntil: new Date(0) })
      .where(eq(schema.messageSearchDocuments.ready, false))
    expect((await drain()).indexed).toBe(1)
    expect((await search(ctx, "worker")).hits).toHaveLength(3)
  })

  test("older postings, a page of rejected phrases, and full paginated agreement with an independent fixture", async () => {
    const { user, chat, ctx } = await fixture()
    const rows = Array.from({ length: 215 }, (_, i) => ({
      chatId: chat.id,
      fromId: user.id,
      messageId: i + 1,
      text: i < 3 ? "rare exact target" : "target exact",
    }))
    await db.insert(schema.messages).values(rows)
    while ((await drain()).examined > 0) {}
    expect(await bootstrapSearchDocuments()).toBe(true)
    const first = await search(ctx, '"exact target"', { limit: 1 })
    expect(first.hits).toEqual([])
    expect(first.nextCursor).toBeDefined()
    expect(first.indexIncomplete).toBe(false)
    let cursor = first.nextCursor
    const ids: bigint[] = []
    while (cursor) {
      const page = await search(ctx, '"exact target"', { limit: 2, cursor })
      ids.push(...page.hits.map((hit) => hit.messageId))
      cursor = page.nextCursor
    }
    expect(ids).toEqual(
      rows
        .filter((row) => row.text.includes("exact target"))
        .reverse()
        .map((row) => BigInt(row.messageId)),
    )
    expect((await search(ctx, "rare")).hits.map((h) => h.messageId)).toEqual([3n, 2n, 1n])
    expect((await search(ctx, "missing")).hits).toEqual([])
  })

  test("an edit of a verified filename is hidden at disclosure even at the same message revision", async () => {
    const { user, chat, ctx } = await fixture()
    const [doc] = await db.insert(schema.documents).values(filename("private.pdf")).returning()
    await db.insert(schema.messages).values({ chatId: chat.id, fromId: user.id, messageId: 1, documentId: doc!.id })
    await drain()
    const original = db.transaction.bind(db)
    let changed = false
    const hook = spyOn(db, "transaction").mockImplementation(
      async <T>(run: (tx: Transaction) => Promise<T>, config?: Parameters<typeof db.transaction>[1]) => {
        const result = await original(run, config)
        if (config?.accessMode === "read only" && !changed) {
          changed = true
          await db.update(schema.documents).set(filename("replacement.pdf")).where(eq(schema.documents.id, doc!.id))
        }
        return result
      },
    )
    try {
      const page = await search(ctx, "private")
      expect(changed).toBe(true)
      expect(page.hits).toEqual([])
      expect(page.indexIncomplete).toBe(true)
    } finally {
      hook.mockRestore()
    }
  })
  test("a previous worker profile published after backfill is reported and repaired", async () => {
    const { user, chat, ctx } = await fixture()
    await testUtils.createTestMessage({ chatId: chat.id, fromId: user.id, messageId: 1, text: "profile" })
    await drain()
    expect(await bootstrapSearchDocuments()).toBe(true)
    await db.update(schema.messageSearchDocuments).set({ tokenizerVersion: "earlier-profile" })
    expect((await search(ctx, "profile")).indexIncomplete).toBe(true)
    expect(await requeueObsoleteSearchDocuments()).toBe(1)
    await drain()
    expect((await search(ctx, "profile")).hits).toHaveLength(1)
    expect(await requeueObsoleteSearchDocuments()).toBe(0)
  })

  test("scope and metadata filters only narrow the reader's visible messages", async () => {
    const { user, chat, ctx } = await fixture()
    const space = (await testUtils.createSpace("Search space"))!
    await db.insert(schema.members).values({ spaceId: space.id, userId: user.id, role: "member" })
    // More than one catalog page of private, unreadable roots precedes the permitted public thread.
    await db.execute(sql`insert into chats(type, space_id, public_thread)
      select 'thread', ${space.id}, false from generate_series(1,510)`)
    const thread = (await testUtils.createChat(space.id, "open thread", "thread", true, user.id))!
    const date = new Date("2026-05-10T12:30:00.700Z")
    const sec = BigInt(Math.floor(date.getTime() / 1000))
    for (const c of [chat, thread]) {
      await db.insert(schema.messages).values({ chatId: c.id, fromId: user.id, messageId: 1, text: "meeting", date })
    }
    await db.insert(schema.dialogs).values({ userId: user.id, chatId: chat.id, archived: true })
    await drain()
    expect(
      (await search(ctx, "meeting", { spaceId: BigInt(space.id), minDate: sec, maxDate: sec })).hits.map(
        (h) => h.chatId,
      ),
    ).toEqual([BigInt(thread.id)])
    expect((await search(ctx, "meeting", { homeOnly: true })).hits.map((h) => h.chatId)).toEqual([BigInt(chat.id)])
    expect((await search(ctx, "meeting", { includeArchived: false })).hits.map((h) => h.chatId)).toEqual([
      BigInt(thread.id),
    ])
    expect((await search(ctx, "meeting", { fromUserId: 2147483647n })).hits).toEqual([])
    expect((await search(ctx, "meeting", { minDate: sec + 1n })).hits).toEqual([])
  })

  test("legacy rows above the normal byte budget remain usable and bounded", async () => {
    const { ctx, user, chat } = await fixture()
    await db.execute(sql`insert into messages(chat_id,message_id,from_id,text) values
      (${chat.id},1,${user.id},'archive' || repeat(' ',2100000)),
      (${chat.id},2,${user.id},'oversized' || repeat(' ',8400000))`)
    const batch = await runCloudSearchIndexBatch()
    expect(batch.indexed).toBe(1)
    expect(batch.failed).toBe(1)
    const result = await search(ctx, "archive")
    expect(result.hits.map((hit) => hit.messageId)).toEqual([1n])
    expect(result.indexIncomplete).toBe(true)
    await db
      .update(schema.messages)
      .set({ text: "smaller replacement" })
      .where(and(eq(schema.messages.chatId, chat.id), eq(schema.messages.messageId, 2)))
    await drain()
    expect((await search(ctx, "smaller")).indexIncomplete).toBe(false)
  })
  test("a later discovery batch can supply the newest result", async () => {
    const { ctx, user, chat } = await fixture()
    let last = chat
    for (let i = 0; i < 65; i++) {
      const other = await testUtils.createUser(`many-${i}@example.test`)
      last = (await testUtils.createPrivateChat(user, other))!
    }
    const stamp = new Date()
    for (const c of [chat, last])
      await db.insert(schema.messages).values({
        chatId: c.id,
        fromId: user.id,
        messageId: 1,
        text: "across batches",
        date: stamp,
      })
    await drain()
    const first = await search(ctx, "across", { limit: 1 })
    const second = await search(ctx, "across", { limit: 1, cursor: first.nextCursor! })
    expect([first.hits[0]!.chatId, second.hits[0]!.chatId]).toEqual([BigInt(last.id), BigInt(chat.id)])
    expect(second.nextCursor).toBeUndefined()
  })

  test("disabling capture fences old work and resumes from an empty historical checkpoint", async () => {
    const { chat, user, ctx } = await fixture()
    const [doc] = await db.insert(schema.documents).values(filename("original.pdf")).returning()
    await db.insert(schema.messages).values({ chatId: chat.id, fromId: user.id, messageId: 1, documentId: doc!.id })
    expect(await bootstrapSearchDocuments()).toBe(true)
    const old = await runCloudSearchIndexBatch({
      beforePublish: async () => {
        await db.execute(sql`select inline_search_set_capture(false)`)
        try {
          await db.update(schema.documents).set(filename("changed.pdf"))
          await testUtils.createTestMessage({ chatId: chat.id, fromId: user.id, messageId: 2, text: "during pause" })
          expect(await bootstrapSearchDocuments()).toBe(false)
          expect(await db.select().from(schema.messageSearchDocuments)).toHaveLength(0)
          await expect(search(ctx, "changed")).rejects.toMatchObject({ codeNumber: 503 })
        } finally {
          await db.execute(sql`select inline_search_set_capture(true)`)
        }
        expect((await search(ctx, "changed")).indexIncomplete).toBe(true)
        expect(await bootstrapSearchDocuments()).toBe(true)
        await drain()
      },
    })
    expect(old.superseded).toBe(1)
    expect((await search(ctx, "original")).hits).toEqual([])
    expect((await search(ctx, "changed")).hits).toHaveLength(1)
    expect((await search(ctx, "pause")).indexIncomplete).toBe(false)
  })

  test("live work precedes historical backlog, retries back off and an edit repairs quarantined rows", async () => {
    const { chat, user, ctx } = await fixture()
    await db.execute(sql`insert into messages(chat_id,message_id,from_id,text)
      select ${chat.id},i,${user.id},'history' from generate_series(1,20) i`)
    await db.delete(schema.messageSearchDocuments)
    await bootstrapSearchDocuments()
    const [bad] = await db
      .insert(schema.messages)
      .values({ chatId: chat.id, fromId: user.id, messageId: 21, textIv: Buffer.alloc(12) })
      .returning()
    for (let attempt = 1; attempt <= 5; attempt++) {
      expect((await runCloudSearchIndexBatch({ limit: 1 })).failed).toBe(1)
      const [row] = await db
        .select()
        .from(schema.messageSearchDocuments)
        .where(eq(schema.messageSearchDocuments.messageGlobalId, bad!.globalId))
      expect(row!.failedAttempts).toBe(attempt)
      if (attempt < 5) {
        expect(row!.claimUntil!.getTime() - Date.now()).toBeGreaterThan(29_000 * 2 ** (attempt - 1))
        await db
          .update(schema.messageSearchDocuments)
          .set({ claimUntil: new Date(0) })
          .where(eq(schema.messageSearchDocuments.messageGlobalId, bad!.globalId))
      }
    }
    await testUtils.createTestMessage({ chatId: chat.id, fromId: user.id, messageId: 22, text: "live" })
    expect((await runCloudSearchIndexBatch({ limit: 1 })).indexed).toBe(1)
    expect((await search(ctx, "live")).hits).toHaveLength(1)
    expect((await runCloudSearchIndexBatch({ historicalOnly: true, limit: 20 })).indexed).toBe(20)
    expect((await runCloudSearchIndexBatch()).examined).toBe(0)
    expect((await search(ctx, "live")).indexIncomplete).toBe(true)
    await db
      .update(schema.messages)
      .set({ textIv: null, text: "recovered" })
      .where(eq(schema.messages.globalId, bad!.globalId))
    await drain()
    expect((await search(ctx, "recovered")).indexIncomplete).toBe(false)
  })

  test("history is paced per worker while live sends are not", async () => {
    const { chat, user, ctx } = await fixture()
    await db.execute(sql`insert into messages(chat_id,message_id,from_id,text)
      select ${chat.id},i,${user.id},'history' from generate_series(1,40) i`)
    await db.delete(schema.messageSearchDocuments)
    const indexedHistory = async () => {
      const [row] = await db.execute<{ count: number }>(sql`select count(*)::int as count
        from message_search_documents where historical and ready`)
      return row!.count
    }
    const worker = new CloudSearchWorker()
    await worker.pollOnce() // The drained queue is refilled from the scan.
    expect(await indexedHistory()).toBe(0)
    await worker.pollOnce()
    expect(await indexedHistory()).toBe(HISTORY_BATCH)
    expect(worker.historyNotBefore - Date.now()).toBeGreaterThan(1_000)
    await testUtils.createTestMessage({ chatId: chat.id, fromId: user.id, messageId: 41, text: "unpaced" })
    await worker.pollOnce()
    expect(await indexedHistory()).toBe(HISTORY_BATCH)
    expect((await search(ctx, "unpaced")).hits).toHaveLength(1)
    worker.historyNotBefore = 0
    await worker.pollOnce()
    expect(await indexedHistory()).toBe(2 * HISTORY_BATCH)
    await worker.stop()

    expect(historyPauseMs(0, 5)).toBe(0)
    // A quick batch waits out the rate cap; a slow one keeps history to a fifth of the time.
    expect(historyPauseMs(16, 100)).toBe(1_900)
    expect(historyPauseMs(16, 1_000)).toBe(4_000)
    expect(historyPauseMs(16, 60_000)).toBe(30_000)
  })

  test("the reader rollout switch and stored bot identity independently deny retrieval", async () => {
    const { ctx, user } = await fixture()
    process.env["CLOUD_MESSAGE_SEARCH_ENABLED"] = "false"
    try {
      await expect(search(ctx, "hidden")).rejects.toMatchObject({ codeNumber: 503 })
    } finally {
      process.env["CLOUD_MESSAGE_SEARCH_ENABLED"] = "true"
    }
    await db.update(schema.users).set({ bot: true }).where(eq(schema.users.id, user.id))
    await expect(search({ ...ctx, isBot: false }, "hidden")).rejects.toMatchObject({ codeNumber: 403 })
  })
})
