import { afterEach, describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import {
  ChatListKind,
  ChatListOrder,
  ChatListScope,
  Method,
  type ChatListFilter,
  type ChatListOffset,
  type GetChatsInput,
} from "@inline-chat/protocol/core"
import { testUtils, defaultTestContext, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { getChats } from "@in/server/functions/messages.getChats"
import { getSpaces } from "@in/server/functions/space.getSpaces"
import { clearChatHistory } from "@in/server/functions/messages.clearChatHistory"
import { MessageModel } from "@in/server/db/models/messages"
import { handleRpcCall } from "@in/server/realtime/handlers/_rpc"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { FunctionContext } from "@in/server/functions/_types"
import { setChatAccessTrustForTests } from "@in/server/modules/authorization/chatAccessTrust"
import { verifyChatAccess } from "@in/server/modules/authorization/chatAccessVerifier"
import { CHAT_LIST_MAX_LIMIT } from "@in/server/modules/chatList/pagedChatList"

const context = (userId: number): FunctionContext => ({
  currentUserId: userId,
  currentSessionId: defaultTestContext.sessionId,
})

type PageInput = Partial<Omit<GetChatsInput, "filter">> & { filter?: Partial<ChatListFilter> }

const pageInput = (fields: PageInput): Partial<GetChatsInput> => ({
  limit: 50,
  ...fields,
  filter: fields.filter ? { kinds: [], spaceIds: [], ...fields.filter } : undefined,
})

const ids = (chats: { id: bigint }[]) => chats.map((chat) => Number(chat.id))
const sorted = (values: number[]) => [...values].sort((a, b) => a - b)

async function page(userId: number, fields: PageInput) {
  return getChats(pageInput(fields), context(userId))
}

async function walk(userId: number, fields: PageInput) {
  const pages: Awaited<ReturnType<typeof page>>[] = []
  let offset: ChatListOffset | undefined
  for (let guard = 0; guard < 100; guard += 1) {
    const result = await page(userId, { ...fields, offset })
    pages.push(result)
    if (!result.nextOffset) return { pages, all: pages.flatMap((item) => ids(item.chats)) }
    offset = result.nextOffset
  }
  throw new Error("pagination did not finish")
}

async function dialogRows(userId: number) {
  return db.select().from(schema.dialogs).where(eq(schema.dialogs.userId, userId))
}

/** Access modes: the stored `chat_access` table, and the projection fallback. */
const accessModes = [
  { name: "stored chat_access", trusted: true },
  { name: "access projection fallback", trusted: false },
] as const

async function useAccessMode(trusted: boolean) {
  if (trusted) {
    await verifyChatAccess({ repair: true })
    setChatAccessTrustForTests(true)
  } else {
    setChatAccessTrustForTests(false)
  }
}

/**
 * Reader catalog: space chats in two spaces, a denied private thread, a DM, a
 * home thread with hidden, unopened and nested children, and a thread in a
 * Space the reader has left while keeping its dialog.
 */
async function createCatalog() {
  const { space, users: [owner, reader] } = await testUtils.createSpaceWithMembers("Paged chats", [
    "paged-owner@example.test", "paged-reader@example.test",
  ])
  const [otherSpace] = await db.insert(schema.spaces).values({ name: "Other space" }).returning()
  const [revokedSpace] = await db.insert(schema.spaces).values({ name: "Revoked space" }).returning()
  if (!otherSpace || !revokedSpace) throw new Error("Spaces not created")
  await db.insert(schema.members).values([
    { spaceId: otherSpace.id, userId: owner.id, role: "member" },
    { spaceId: otherSpace.id, userId: reader.id, role: "member" },
    { spaceId: revokedSpace.id, userId: owner.id, role: "member" },
    { spaceId: revokedSpace.id, userId: reader.id, role: "member" },
  ])

  const publicThread = await testUtils.createChat(space.id, "Public", "thread", true, owner.id)
  const privateThread = await testUtils.createChat(space.id, "Private", "thread", false, owner.id)
  const denied = await testUtils.createChat(space.id, "Denied", "thread", false, owner.id)
  const otherSpaceThread = await testUtils.createChat(otherSpace.id, "Other", "thread", true, owner.id)
  const revoked = await testUtils.createChat(revokedSpace.id, "Revoked", "thread", false, owner.id)
  const home = await testUtils.createChat(null, "Home", "thread", false, owner.id)
  const dm = await testUtils.createPrivateChat(owner, reader)
  if (!publicThread || !privateThread || !denied || !otherSpaceThread || !revoked || !home || !dm) {
    throw new Error("Chats not created")
  }
  await testUtils.addParticipant(privateThread.id, reader.id)
  await testUtils.addParticipant(denied.id, owner.id)
  await testUtils.addParticipant(revoked.id, reader.id)
  await testUtils.addParticipant(home.id, owner.id)
  await testUtils.addParticipant(home.id, reader.id)

  const [hidden, unopened] = await db.insert(schema.chats).values([
    { type: "thread", title: "Hidden child", parentChatId: home.id },
    { type: "thread", title: "Unopened child", parentChatId: home.id },
  ]).returning()
  if (!hidden || !unopened) throw new Error("Children not created")
  const [nested] = await db.insert(schema.chats).values({ type: "thread", title: "Nested", parentChatId: unopened.id }).returning()
  if (!nested) throw new Error("Nested child not created")

  // Dialogs the reader holds: roots except the home thread, a hidden child,
  // and a dialog in the Space the reader is about to leave.
  await db.insert(schema.dialogs).values([
    { chatId: publicThread.id, userId: reader.id, spaceId: space.id },
    { chatId: privateThread.id, userId: reader.id, spaceId: space.id },
    { chatId: otherSpaceThread.id, userId: reader.id, spaceId: otherSpace.id },
    { chatId: dm.id, userId: reader.id, peerUserId: owner.id, open: true },
    { chatId: hidden.id, userId: reader.id, chatListHidden: true },
    { chatId: revoked.id, userId: reader.id, spaceId: revokedSpace.id },
  ])

  await db.delete(schema.members).where(and(
    eq(schema.members.spaceId, revokedSpace.id), eq(schema.members.userId, reader.id),
  ))

  return {
    owner, reader, space, otherSpace,
    chats: { publicThread, privateThread, denied, otherSpaceThread, revoked, home, dm, hidden, unopened, nested },
  }
}

/** Public threads with dialogs and controlled activity dates, two sharing one second. */
async function createTimeline() {
  const { space, users: [owner, reader] } = await testUtils.createSpaceWithMembers("Timeline", [
    "timeline-owner@example.test", "timeline-reader@example.test",
  ])
  const base = Date.UTC(2026, 0, 1)
  const at = (seconds: number) => new Date(base + seconds * 1000)
  // [created, last message] in seconds from base; null = no message yet.
  const shape: [number, number | null][] = [[0, 50], [1, null], [2, 30], [3, 30], [4, 90], [5, 10], [6, null]]
  const created = await db.insert(schema.chats).values(shape.map(([createdAt, lastAt], index) => ({
    type: "thread" as const,
    title: `Timeline ${index}`,
    spaceId: space.id,
    publicThread: true,
    createdBy: owner.id,
    date: at(createdAt),
    lastMessageDate: lastAt === null ? null : at(lastAt + 0.25 * index),
  }))).returning()
  await db.insert(schema.dialogs).values(created.map((chat) => ({ chatId: chat.id, userId: reader.id, spaceId: space.id })))
  const activity = (chat: schema.DbChat) => Math.floor((chat.lastMessageDate ?? chat.date).getTime() / 1000)
  const recent = [...created]
    .sort((a, b) => activity(b) - activity(a) || b.id - a.id)
    .map((chat) => chat.id)
  return { space, owner, reader, created, recent, activity }
}

describe("getChats paged", () => {
  setupTestLifecycle()
  afterEach(() => setChatAccessTrustForTests(false))

  for (const mode of accessModes) {
    describe(mode.name, () => {
      test("walks both orders in pages with next_offset, ties broken by chat ID", async () => {
        const { reader, created, recent, activity } = await createTimeline()
        const [folder] = await db.insert(schema.dialogFolders).values({ userId: reader.id, title: "Work", order: "a" }).returning()
        await useAccessMode(mode.trusted)

        const byRecent = await walk(reader.id, { limit: 3 })
        expect(byRecent.all).toEqual(recent)
        expect(byRecent.pages.map((item) => item.chats.length)).toEqual([3, 3, 1])
        expect(byRecent.pages.at(-1)!.nextOffset).toBeUndefined()
        const first = byRecent.pages[0]!
        const lastOfFirst = created.find((chat) => chat.id === recent[2])!
        expect(first.nextOffset).toEqual({ chatId: BigInt(recent[2]!), date: BigInt(activity(lastOfFirst)) })
        expect(first.folders.map((item) => Number(item.id))).toEqual([folder!.id])
        expect(byRecent.pages.slice(1).every((item) => item.folders.length === 0)).toBe(true)

        const byId = await walk(reader.id, { limit: 3, order: ChatListOrder.ID })
        expect(byId.all).toEqual(sorted(created.map((chat) => chat.id)))
        expect(byId.pages[0]!.nextOffset).toEqual({ chatId: BigInt(byId.all[2]!) })

        // An exact fit still ends with next_offset absent, not a trailing empty page.
        const exact = await page(reader.id, { limit: created.length })
        expect(exact.chats).toHaveLength(created.length)
        expect(exact.nextOffset).toBeUndefined()
      })

      test("a dialog whose chat access was revoked is not listed in either scope or order", async () => {
        const { space, users: [owner, reader] } = await testUtils.createSpaceWithMembers("Revoked access", [
          "revoked-owner@example.test", "revoked-reader@example.test",
        ])
        const kept = await testUtils.createChat(space.id, "Kept", "thread", true, owner.id)
        const revoked = await testUtils.createChat(space.id, "Revoked", "thread", false, owner.id)
        if (!kept || !revoked) throw new Error("Chats not created")
        await testUtils.addParticipant(revoked.id, owner.id)
        await testUtils.addParticipant(revoked.id, reader.id)
        await db.insert(schema.dialogs).values([
          { chatId: kept.id, userId: reader.id, spaceId: space.id },
          { chatId: revoked.id, userId: reader.id, spaceId: space.id, open: true },
        ])
        // Removing the participant revokes access; the reader's dialog row stays.
        await db.delete(schema.chatParticipants).where(and(
          eq(schema.chatParticipants.chatId, revoked.id), eq(schema.chatParticipants.userId, reader.id),
        ))
        await useAccessMode(mode.trusted)

        for (const scope of [ChatListScope.DIALOGS, ChatListScope.ACCESSIBLE]) {
          for (const order of [ChatListOrder.RECENT, ChatListOrder.ID]) {
            const { pages, all } = await walk(reader.id, { limit: 1, scope, order })
            expect(all).toEqual([kept.id])
            for (const item of pages) {
              expect(item.dialogs.map((dialog) => Number(dialog.chatId))).not.toContain(revoked.id)
            }
          }
        }
        expect((await dialogRows(reader.id)).map((dialog) => dialog.chatId)).toContain(revoked.id)
      })

      test("ID order pages are complete for their ranges", async () => {
        const { space, users: [owner, reader] } = await testUtils.createSpaceWithMembers("Ranges", [
          "ranges-owner@example.test", "ranges-reader@example.test",
        ])
        const created = await db.insert(schema.chats).values(
          Array.from({ length: 23 }, (_, index) => ({
            type: "thread" as const,
            title: `Thread ${index}`,
            spaceId: space.id,
            // Every third thread is private without the reader: inaccessible.
            publicThread: index % 3 !== 0,
            createdBy: owner.id,
          })),
        ).returning()
        await useAccessMode(mode.trusted)
        const accessible = sorted(created.filter((chat) => chat.publicThread).map((chat) => chat.id))

        const { pages, all } = await walk(reader.id, { limit: 4, order: ChatListOrder.ID, scope: ChatListScope.ACCESSIBLE })
        expect(all).toEqual(accessible)
        let lower = 0
        for (const [index, item] of pages.entries()) {
          const upper = item.nextOffset ? Number(item.nextOffset.chatId) : Number.POSITIVE_INFINITY
          expect(ids(item.chats)).toEqual(accessible.filter((id) => id > lower && id <= upper))
          if (index < pages.length - 1) expect(item.chats).toHaveLength(4)
          lower = upper
        }
      })

      test("DIALOGS scope lists stored dialogs; ACCESSIBLE adds chats without one and creates none", async () => {
        const { reader, chats } = await createCatalog()
        await useAccessMode(mode.trusted)
        const before = await dialogRows(reader.id)

        const dialogScope = await walk(reader.id, { limit: 2, order: ChatListOrder.ID })
        expect(dialogScope.all).toEqual(sorted([
          chats.publicThread.id, chats.privateThread.id, chats.otherSpaceThread.id, chats.dm.id,
        ]))
        // The dialog kept after leaving the Space is not listed.
        expect(dialogScope.all).not.toContain(chats.revoked.id)

        const accessible = await walk(reader.id, { limit: 3, order: ChatListOrder.ID, scope: ChatListScope.ACCESSIBLE })
        const expected = sorted([
          chats.publicThread.id, chats.privateThread.id, chats.otherSpaceThread.id, chats.home.id, chats.dm.id,
          chats.hidden.id, chats.unopened.id, chats.nested.id,
        ])
        expect(accessible.all).toEqual(expected)
        for (const excluded of [chats.denied.id, chats.revoked.id]) expect(accessible.all).not.toContain(excluded)

        // include_subthreads is the legacy spelling of ACCESSIBLE.
        expect((await walk(reader.id, { limit: 3, order: ChatListOrder.ID, includeSubthreads: true })).all).toEqual(expected)

        const homePage = accessible.pages.find((item) => ids(item.chats).includes(chats.home.id))!
        expect(homePage.dialogs.map((dialog) => Number(dialog.chatId))).not.toContain(chats.home.id)
        expect(await dialogRows(reader.id)).toEqual(before)

        // Same set as the legacy complete snapshot.
        const legacy = await getChats({ includeSubthreads: true }, context(reader.id))
        expect(sorted(ids(legacy.chats))).toEqual(expected)
      })

      test("filters by kind, space, unread, archived, open, pinned and folder", async () => {
        const { owner, reader, space, otherSpace, chats } = await createCatalog()
        const [folder] = await db.insert(schema.dialogFolders).values({ userId: reader.id, title: "F", order: "a" }).returning()
        const setDialog = (chatId: number, fields: Partial<schema.DbNewDialog>) =>
          db.update(schema.dialogs).set(fields).where(and(eq(schema.dialogs.chatId, chatId), eq(schema.dialogs.userId, reader.id)))
        await setDialog(chats.publicThread.id, { archived: true, pinned: true })
        await setDialog(chats.privateThread.id, { open: true, folderId: folder!.id })
        await setDialog(chats.otherSpaceThread.id, { unreadMark: true })
        // An unread message from the owner in the DM; the reader's own message does not count.
        await MessageModel.insertMessage({ chatId: chats.dm.id, fromId: owner.id })
        await MessageModel.insertMessage({ chatId: chats.publicThread.id, fromId: reader.id })
        await useAccessMode(mode.trusted)

        const list = async (filter: Partial<ChatListFilter>, scope = ChatListScope.ACCESSIBLE) =>
          sorted((await walk(reader.id, { limit: 2, order: ChatListOrder.ID, scope, filter })).all)

        expect(await list({ kinds: [ChatListKind.DM] })).toEqual([chats.dm.id])
        expect(await list({ kinds: [ChatListKind.HOME_THREAD] }))
          .toEqual(sorted([chats.home.id, chats.hidden.id, chats.unopened.id, chats.nested.id]))
        expect(await list({ kinds: [ChatListKind.SPACE_THREAD], spaceIds: [BigInt(space.id)] }))
          .toEqual(sorted([chats.publicThread.id, chats.privateThread.id]))
        // space_ids restricts space threads only; DMs and home threads stay.
        expect(await list({ kinds: [ChatListKind.SPACE_THREAD, ChatListKind.DM], spaceIds: [BigInt(otherSpace.id)] }))
          .toEqual(sorted([chats.otherSpaceThread.id, chats.dm.id]))

        expect(await list({ unread: true })).toEqual(sorted([chats.otherSpaceThread.id, chats.dm.id]))
        expect(await list({ unread: false }, ChatListScope.DIALOGS))
          .toEqual(sorted([chats.publicThread.id, chats.privateThread.id]))
        expect(await list({ archived: true })).toEqual([chats.publicThread.id])
        expect(await list({ archived: false }, ChatListScope.DIALOGS))
          .toEqual(sorted([chats.privateThread.id, chats.otherSpaceThread.id, chats.dm.id]))
        expect(await list({ pinned: true })).toEqual([chats.publicThread.id])
        expect(await list({ open: true }, ChatListScope.DIALOGS)).toEqual(sorted([chats.privateThread.id, chats.dm.id]))
        expect(await list({ open: true, pinned: false }, ChatListScope.DIALOGS))
          .toEqual(sorted([chats.privateThread.id, chats.dm.id]))
        expect(await list({ folderId: BigInt(folder!.id) })).toEqual([chats.privateThread.id])

        // The filtered page hydrates unread counts for its dialogs.
        const unread = await page(reader.id, { filter: { unread: true, kinds: [ChatListKind.DM] } })
        expect(unread.dialogs.map((dialog) => [Number(dialog.chatId), dialog.unreadCount])).toEqual([[chats.dm.id, 1]])
      })

      test("hydrates the page like the snapshot: last messages, referenced users and spaces only", async () => {
        const { owner, reader, space, chats } = await createCatalog()
        await MessageModel.insertMessage({ chatId: chats.dm.id, fromId: owner.id })
        // The DM has no stored dialog: the page still references its peer.
        await db.delete(schema.dialogs).where(and(eq(schema.dialogs.chatId, chats.dm.id), eq(schema.dialogs.userId, reader.id)))
        await useAccessMode(mode.trusted)

        const result = await page(reader.id, {
          scope: ChatListScope.ACCESSIBLE,
          filter: { kinds: [ChatListKind.DM, ChatListKind.SPACE_THREAD], spaceIds: [BigInt(space.id)] },
        })
        // RECENT: the DM has a message, the others order by creation date.
        expect(ids(result.chats)).toEqual([chats.dm.id, chats.privateThread.id, chats.publicThread.id])
        // Dialogs follow list order; the DM has none.
        expect(result.dialogs.map((dialog) => Number(dialog.chatId))).toEqual([chats.privateThread.id, chats.publicThread.id])
        expect(result.messages.map((message) => [Number(message.chatId), Number(message.id)])).toEqual([[chats.dm.id, 1]])
        expect(result.users.map((user) => Number(user.id))).toEqual([owner.id])
        expect(result.spaces.map((item) => Number(item.id))).toEqual([space.id])
        expect(result.nextOffset).toBeUndefined()

        const legacyDm = (await getChats({}, context(reader.id))).chats.find((chat) => Number(chat.id) === chats.dm.id)
        expect(result.chats[0]).toEqual(legacyDm!)
      })
    })
  }

  test("validates requests and caps the limit", async () => {
    const { space, users: [owner, reader] } = await testUtils.createSpaceWithMembers("Caps", [
      "caps-owner@example.test", "caps-reader@example.test",
    ])
    await db.insert(schema.chats).values(Array.from({ length: CHAT_LIST_MAX_LIMIT + 5 }, (_, index) => ({
      type: "thread" as const, title: `Cap ${index}`, spaceId: space.id, publicThread: true, createdBy: owner.id,
    })))

    const capped = await page(reader.id, { limit: 1_000, scope: ChatListScope.ACCESSIBLE })
    expect(capped.chats).toHaveLength(CHAT_LIST_MAX_LIMIT)
    expect(capped.nextOffset).toBeDefined()

    const rejects = async (fields: PageInput, reason: string) =>
      expect(page(reader.id, fields)).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST, message: reason })
    await rejects({ filter: { query: "roadmap" } }, "filter.query is not supported yet")
    await rejects({ limit: 0 }, "limit must be at least 1")
    await rejects({ offset: { chatId: 5n } }, "offset.date is required in RECENT order")
    await rejects({ offset: { chatId: -1n }, order: ChatListOrder.ID }, "offset.chat_id must be a positive ID")
    await rejects({ filter: { kinds: [ChatListKind.UNSPECIFIED] } }, "unknown chat kind")

    // Over realtime RPC the reason reaches the caller.
    const handlerContext = { userId: reader.id, sessionId: 1, connectionId: "paged-test", sendRaw: () => {}, sendRpcReply: () => {} }
    await expect(handleRpcCall(
      { method: Method.GET_CHATS, input: { oneofKind: "getChats", getChats: pageInput({ filter: { query: "x" } }) as GetChatsInput } },
      handlerContext,
    )).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })

  test("legacy unpaged requests keep creating dialogs and return no next_offset", async () => {
    const { reader, chats } = await createCatalog()
    await db.delete(schema.dialogs).where(eq(schema.dialogs.userId, reader.id))

    const result = await getChats({}, context(reader.id))
    expect(result.nextOffset).toBeUndefined()
    expect(sorted(ids(result.chats))).toEqual(sorted([
      chats.publicThread.id, chats.privateThread.id, chats.otherSpaceThread.id, chats.home.id, chats.dm.id,
    ]))
    expect(sorted(result.dialogs.map((dialog) => Number(dialog.chatId)))).toEqual(sorted(ids(result.chats)))
    expect(sorted((await dialogRows(reader.id)).map((dialog) => dialog.chatId))).toEqual(sorted(ids(result.chats)))
  })
})

describe("chats.last_message_date", () => {
  setupTestLifecycle()

  const readChat = async (chatId: number) => {
    const [chat] = await db.select().from(schema.chats).where(eq(schema.chats.id, chatId))
    return chat!
  }

  test("follows the last message on send, delete-last and clear-history", async () => {
    const userA = await testUtils.createUser("lmd-a@example.test")
    const userB = await testUtils.createUser("lmd-b@example.test")
    const chat = await testUtils.createPrivateChat(userA, userB)
    if (!chat) throw new Error("Chat not created")
    const first = new Date(Date.UTC(2026, 0, 1, 10))
    const second = new Date(Date.UTC(2026, 0, 2, 10))

    await MessageModel.insertMessage({ chatId: chat.id, fromId: userA.id, date: first })
    await MessageModel.insertMessage({ chatId: chat.id, fromId: userB.id, date: second })
    expect(await readChat(chat.id)).toMatchObject({ lastMsgId: 2, lastMessageDate: second })

    await MessageModel.deleteMessages([2n], chat.id)
    expect(await readChat(chat.id)).toMatchObject({ lastMsgId: 1, lastMessageDate: first })

    await clearChatHistory(
      { peer: { type: { oneofKind: "user", user: { userId: BigInt(userB.id) } } }, keepLastDays: 0, deleteReplyThreads: false },
      testUtils.functionContext({ userId: userA.id }),
    )
    expect(await readChat(chat.id)).toMatchObject({ lastMsgId: null, lastMessageDate: null })
  })
})

describe("getSpaces", () => {
  setupTestLifecycle()

  test("returns every non-deleted space the viewer is a member of", async () => {
    const { space, users: [member] } = await testUtils.createSpaceWithMembers("Mine", ["spaces-member@example.test"])
    const [deleted] = await db.insert(schema.spaces).values({ name: "Deleted", deleted: new Date() }).returning()
    await testUtils.createSpace("Not mine")
    await db.insert(schema.members).values({ spaceId: deleted!.id, userId: member.id, role: "member" })

    const result = await getSpaces({}, context(member.id))
    expect(result.spaces.map((item) => [Number(item.id), item.name])).toEqual([[space.id, "Mine"]])

    const handlerContext = { userId: member.id, sessionId: 1, connectionId: "spaces-test", sendRaw: () => {}, sendRpcReply: () => {} }
    const rpc = await handleRpcCall({ method: Method.GET_SPACES, input: { oneofKind: "getSpaces", getSpaces: {} } }, handlerContext)
    if (rpc.oneofKind !== "getSpaces") throw new Error("Unexpected result")
    expect(rpc.getSpaces.spaces.map((item) => Number(item.id))).toEqual([space.id])
  })
})
