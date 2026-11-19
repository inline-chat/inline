import { afterEach, describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { Method, type ChatListOffset, type GetCommonChatsInput } from "@inline-chat/protocol/core"
import { defaultTestContext, setupTestLifecycle, testUtils } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { MessageModel } from "@in/server/db/models/messages"
import { getCommonChats } from "@in/server/functions/messages.getCommonChats"
import type { FunctionContext } from "@in/server/functions/_types"
import { setChatAccessTrustForTests } from "@in/server/modules/authorization/chatAccessTrust"
import { verifyChatAccess } from "@in/server/modules/authorization/chatAccessVerifier"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { handleRpcCall } from "@in/server/realtime/handlers/_rpc"

const context = (userId: number): FunctionContext => ({
  currentUserId: userId,
  currentSessionId: defaultTestContext.sessionId,
})

const ids = (chats: { id: bigint }[]) => chats.map((chat) => Number(chat.id))

const common = (viewerId: number, targetId: number, fields: Partial<GetCommonChatsInput> = {}) =>
  getCommonChats({ userId: BigInt(targetId), ...fields }, context(viewerId))

async function walk(viewerId: number, targetId: number, limit: number) {
  const pages: number[][] = []
  let offset: ChatListOffset | undefined
  for (let guard = 0; guard < 50; guard += 1) {
    const result = await common(viewerId, targetId, { limit, offset })
    pages.push(ids(result.chats))
    if (!result.nextOffset) return pages
    offset = result.nextOffset
  }
  throw new Error("pagination did not finish")
}

const base = Date.UTC(2026, 0, 1)
const at = (seconds: number) => new Date(base + seconds * 1000)

async function setActivity(chatId: number, seconds: number) {
  await db.update(schema.chats).set({ lastMessageDate: at(seconds) }).where(eq(schema.chats.id, chatId))
}

/**
 * The viewer and target share a private thread, a group-granted thread and a
 * home thread. Every other thread misses one of the rules.
 */
async function createFixture() {
  const { space, users: [owner, viewer, target] } = await testUtils.createSpaceWithMembers("Common", [
    "common-owner@example.test", "common-viewer@example.test", "common-target@example.test",
  ])
  const [leftSpace] = await db.insert(schema.spaces).values({ name: "Left space" }).returning()
  if (!leftSpace) throw new Error("Space not created")
  await db.insert(schema.members).values([
    { spaceId: leftSpace.id, userId: viewer.id, role: "member" },
    { spaceId: leftSpace.id, userId: target.id, role: "member" },
  ])

  const shared = await testUtils.createChat(space.id, "Shared", "thread", false, owner.id)
  const viewerOnly = await testUtils.createChat(space.id, "Viewer only", "thread", false, owner.id)
  const targetOnly = await testUtils.createChat(space.id, "Target only", "thread", false, owner.id)
  const grouped = await testUtils.createChat(space.id, "Grouped", "thread", false, owner.id)
  const publicThread = await testUtils.createChat(space.id, "Public", "thread", true, owner.id)
  const publicWithRows = await testUtils.createChat(space.id, "Public with rows", "thread", true, owner.id)
  const left = await testUtils.createChat(leftSpace.id, "Left", "thread", false, owner.id)
  const home = await testUtils.createChat(null, "Home", "thread", false, owner.id)
  const dm = await testUtils.createPrivateChat(viewer, target)
  if (!shared || !viewerOnly || !targetOnly || !grouped || !publicThread || !publicWithRows || !left || !home || !dm) {
    throw new Error("Chats not created")
  }
  const [subthread] = await db.insert(schema.chats).values({
    type: "thread", title: "Subthread", spaceId: space.id, publicThread: false, parentChatId: shared.id,
  }).returning()
  if (!subthread) throw new Error("Subthread not created")

  for (const chatId of [shared.id, home.id, left.id, publicWithRows.id, subthread.id]) {
    await testUtils.addParticipant(chatId, viewer.id)
    await testUtils.addParticipant(chatId, target.id)
  }
  await testUtils.addParticipant(viewerOnly.id, viewer.id)
  await testUtils.addParticipant(targetOnly.id, target.id)
  await testUtils.addParticipant(grouped.id, viewer.id)
  const [group] = await db.insert(schema.userGroups).values({ spaceId: space.id, name: "Target's team", createdBy: owner.id }).returning()
  if (!group) throw new Error("Group not created")
  await db.insert(schema.userGroupMembers).values({ groupId: group.id, userId: target.id })
  await db.insert(schema.chatParticipantGroups).values({ groupId: group.id, chatId: grouped.id })

  // The viewer left this space but kept the participant row.
  await db.delete(schema.members).where(and(eq(schema.members.spaceId, leftSpace.id), eq(schema.members.userId, viewer.id)))

  // Recent first: grouped, home, shared. Excluded chats are newer still.
  await setActivity(shared.id, 10)
  await setActivity(home.id, 20)
  await setActivity(grouped.id, 30)
  for (const chatId of [viewerOnly.id, targetOnly.id, publicThread.id, publicWithRows.id, left.id, subthread.id, dm.id]) {
    await setActivity(chatId, 100)
  }

  return {
    space, leftSpace, owner, viewer, target, group,
    chats: { shared, viewerOnly, targetOnly, grouped, publicThread, publicWithRows, left, home, dm, subthread },
  }
}

describe("getCommonChats", () => {
  setupTestLifecycle()
  afterEach(() => setChatAccessTrustForTests(false))

  for (const trusted of [false, true]) {
    test(`lists only top-level threads both users can access${trusted ? " after access backfill" : ""}`, async () => {
      const { space, viewer, target, chats } = await createFixture()
      if (trusted) {
        await verifyChatAccess({ repair: true })
        setChatAccessTrustForTests(true)
      }

      const result = await common(viewer.id, target.id)
      expect(ids(result.chats)).toEqual([chats.grouped.id, chats.home.id, chats.shared.id])
      expect(result.nextOffset).toBeUndefined()
      expect(result.spaces.map((item) => Number(item.id))).toEqual([space.id])

      // The relation is symmetric.
      expect(ids((await common(target.id, viewer.id)).chats)).toEqual([chats.grouped.id, chats.home.id, chats.shared.id])
    })
  }

  test("returns the viewer's own dialogs with unread counts and omits missing ones", async () => {
    const { space, viewer, target, chats } = await createFixture()
    await db.insert(schema.dialogs).values([
      { chatId: chats.shared.id, userId: viewer.id, spaceId: space.id, readInboxMaxId: 0 },
      { chatId: chats.grouped.id, userId: target.id, spaceId: space.id },
    ])
    await MessageModel.insertMessage({ chatId: chats.shared.id, fromId: target.id, date: at(5) })
    await MessageModel.insertMessage({ chatId: chats.shared.id, fromId: target.id, date: at(6) })
    await setActivity(chats.shared.id, 10)

    const result = await common(viewer.id, target.id)
    expect(ids(result.chats)).toEqual([chats.grouped.id, chats.home.id, chats.shared.id])
    expect(result.dialogs.map((dialog) => [Number(dialog.chatId), dialog.unreadCount])).toEqual([[chats.shared.id, 2]])
  })

  test("drops a thread once either user loses access", async () => {
    const { space, viewer, target, chats } = await createFixture()
    await db.delete(schema.chatParticipants).where(and(
      eq(schema.chatParticipants.chatId, chats.shared.id),
      eq(schema.chatParticipants.userId, viewer.id),
    ))
    expect(ids((await common(viewer.id, target.id)).chats)).toEqual([chats.grouped.id, chats.home.id])

    await db.delete(schema.members).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, target.id)))
    expect(ids((await common(viewer.id, target.id)).chats)).toEqual([chats.home.id])

    await db.update(schema.users).set({ deleted: true }).where(eq(schema.users.id, target.id))
    expect((await common(viewer.id, target.id)).chats).toEqual([])
  })

  test("pages in activity order with ties broken by chat ID", async () => {
    const { space, users: [viewer, target] } = await testUtils.createSpaceWithMembers("Common pages", [
      "common-pages-viewer@example.test", "common-pages-target@example.test",
    ])
    // [created, last message] in seconds; two share an activity second, two have no messages.
    const shape: [number, number | null][] = [[0, 50], [1, null], [2, 30], [3, 30], [4, 90], [5, 10], [6, null]]
    const created = await db.insert(schema.chats).values(shape.map(([createdAt, lastAt], index) => ({
      type: "thread" as const,
      title: `Common ${index}`,
      spaceId: space.id,
      publicThread: false,
      date: at(createdAt),
      lastMessageDate: lastAt === null ? null : at(lastAt + 0.25 * index),
    }))).returning()
    await db.insert(schema.chatParticipants).values(created.flatMap((chat) => [
      { chatId: chat.id, userId: viewer.id },
      { chatId: chat.id, userId: target.id },
    ]))
    const activity = (chat: schema.DbChat) => Math.floor((chat.lastMessageDate ?? chat.date).getTime() / 1000)
    const recent = [...created].sort((a, b) => activity(b) - activity(a) || b.id - a.id).map((chat) => chat.id)

    const pages = await walk(viewer.id, target.id, 2)
    expect(pages.map((item) => item.length)).toEqual([2, 2, 2, 1])
    expect(pages.flat()).toEqual(recent)

    const first = await common(viewer.id, target.id, { limit: 3 })
    const last = created.find((chat) => chat.id === recent[2])!
    expect(first.nextOffset).toEqual({ chatId: BigInt(last.id), date: BigInt(activity(last)) })
  })

  test("fills a page past a full batch of candidates the projection rejects", async () => {
    const { space, users: [viewer, target] } = await testUtils.createSpaceWithMembers("Common fill", [
      "common-fill-viewer@example.test", "common-fill-target@example.test",
    ])
    const [leftSpace] = await db.insert(schema.spaces).values({ name: "Common fill left" }).returning()
    if (!leftSpace) throw new Error("Space not created")
    await db.insert(schema.members).values({ spaceId: leftSpace.id, userId: target.id, role: "member" })
    // Both hold grants on every chat, but the viewer is not a member of the newer chats' space.
    const rejected = await db.insert(schema.chats).values(Array.from({ length: 260 }, (_, index) => ({
      type: "thread" as const,
      title: `Rejected ${index}`,
      spaceId: leftSpace.id,
      publicThread: false,
      lastMessageDate: at(1_000 + index),
    }))).returning()
    const listed = await db.insert(schema.chats).values([0, 1].map((index) => ({
      type: "thread" as const,
      title: `Listed ${index}`,
      spaceId: space.id,
      publicThread: false,
      lastMessageDate: at(index),
    }))).returning()
    await db.insert(schema.chatParticipants).values([...rejected, ...listed].flatMap((chat) => [
      { chatId: chat.id, userId: viewer.id },
      { chatId: chat.id, userId: target.id },
    ]))

    const result = await common(viewer.id, target.id, { limit: 1 })
    expect(ids(result.chats)).toEqual([listed[1]!.id])
    expect(result.nextOffset).toBeDefined()
    expect(ids((await common(viewer.id, target.id, { offset: result.nextOffset })).chats)).toEqual([listed[0]!.id])
  })

  test("caps the page size and defaults it to 30", async () => {
    const { space, users: [viewer, target] } = await testUtils.createSpaceWithMembers("Common caps", [
      "common-caps-viewer@example.test", "common-caps-target@example.test",
    ])
    const created = await db.insert(schema.chats).values(Array.from({ length: 101 }, (_, index) => ({
      type: "thread" as const,
      title: `Cap ${index}`,
      spaceId: space.id,
      publicThread: false,
    }))).returning()
    await db.insert(schema.chatParticipants).values(created.flatMap((chat) => [
      { chatId: chat.id, userId: viewer.id },
      { chatId: chat.id, userId: target.id },
    ]))

    expect((await common(viewer.id, target.id)).chats).toHaveLength(30)
    const capped = await common(viewer.id, target.id, { limit: 1_000 })
    expect(capped.chats).toHaveLength(100)
    expect(capped.nextOffset).toBeDefined()
  })

  test("rejects the viewer and invalid input, and returns nothing for an unknown user", async () => {
    const viewer = await testUtils.createUser("common-self@example.test")
    const rejects = (fields: Partial<GetCommonChatsInput>, reason: string) =>
      expect(getCommonChats(fields, context(viewer.id))).rejects.toMatchObject({
        code: RealtimeRpcError.Code.BAD_REQUEST,
        message: reason,
      })
    await rejects({ userId: BigInt(viewer.id) }, "user_id must be another user")
    await rejects({}, "user_id must be a positive ID")
    await rejects({ userId: -4n }, "user_id must be a positive ID")
    await rejects({ userId: 5n, limit: 0 }, "limit must be at least 1")
    await rejects({ userId: 5n, offset: { chatId: 5n } }, "offset.date is required in RECENT order")

    expect(await common(viewer.id, 2_000_000)).toEqual({ chats: [], dialogs: [], spaces: [], nextOffset: undefined })
  })

  test("is served over realtime RPC", async () => {
    const { viewer, target, chats } = await createFixture()
    const handlerContext = { userId: viewer.id, sessionId: 1, connectionId: "common-test", sendRaw: () => {}, sendRpcReply: () => {} }
    const rpc = await handleRpcCall({
      method: Method.GET_COMMON_CHATS,
      input: { oneofKind: "getCommonChats", getCommonChats: { userId: BigInt(target.id), limit: 2 } },
    }, handlerContext)
    if (rpc.oneofKind !== "getCommonChats") throw new Error("Unexpected result")
    expect(ids(rpc.getCommonChats.chats)).toEqual([chats.grouped.id, chats.home.id])
    expect(rpc.getCommonChats.nextOffset).toBeDefined()

    await expect(handleRpcCall({
      method: Method.GET_COMMON_CHATS,
      input: { oneofKind: "getCommonChats", getCommonChats: { userId: BigInt(viewer.id) } },
    }, handlerContext)).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })
})
