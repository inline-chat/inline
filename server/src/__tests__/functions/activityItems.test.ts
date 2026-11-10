import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { MessageEntity_Type as T, type InputPeer, type MessageEntities } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import {
  ACTIVITY_KIND_MENTION,
  ACTIVITY_KIND_REACTION,
  ACTIVITY_KIND_REPLY,
  activityItems,
  members,
  updates,
  UpdateBucket,
  users,
} from "@in/server/db/schema"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { readMessages } from "@in/server/functions/messages.readMessages"
import { deleteMessage } from "@in/server/functions/messages.deleteMessage"
import { getChats } from "@in/server/functions/messages.getChats"
import { addReaction } from "@in/server/functions/messages.addReaction"
import { deleteReaction } from "@in/server/functions/messages.deleteReaction"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"
import { UpdatesModel } from "@in/server/db/models/updates"
import { applicationBackgroundWork } from "@in/server/lifecycle/backgroundWork"
import { listUnreadActivity, planMessageActivity, readActivity } from "@in/server/modules/activityItems"
import { setupTestLifecycle, testUtils } from "../setup"

let sequence = 0
const run = Date.now()
const user = (label: string) => testUtils.createUser(`activity-${label}-${run}-${sequence++}@example.com`)

const mention = (userId: number, offset = 0, length = 4): MessageEntities => ({
  entities: [
    {
      type: T.MENTION,
      offset: BigInt(offset),
      length: BigInt(length),
      entity: { oneofKind: "mention", mention: { userId: BigInt(userId) } },
    },
  ],
})

async function threadFixture() {
  const alice = await user("alice"), bob = await user("bob"), carol = await user("carol")
  const space = await testUtils.createSpace("Activity")
  if (!space) throw new Error("Missing test space")
  await db.insert(members).values([
    { spaceId: space.id, userId: alice.id, role: "owner" },
    { spaceId: space.id, userId: bob.id, role: "member" },
    { spaceId: space.id, userId: carol.id, role: "member" },
  ])
  const chat = await testUtils.createChat(space.id, "Activity", "thread", false, alice.id)
  if (!chat) throw new Error("Missing test chat")
  for (const member of [alice, bob, carol]) await testUtils.addParticipant(chat.id, member.id)
  const peer: InputPeer = { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }
  const as = (u: { id: number }) => testUtils.functionContext({ userId: u.id, sessionId: 1 })
  return { alice, bob, carol, chat, peer, as }
}

async function send(
  peer: InputPeer,
  context: ReturnType<typeof testUtils.functionContext>,
  input: { message: string; entities?: MessageEntities; replyToMessageId?: bigint },
) {
  await sendMessage({ peerId: peer, ...input }, context)
  await applicationBackgroundWork.waitForIdle()
}

async function rows(chatId: number, userId: number) {
  return await db
    .select()
    .from(activityItems)
    .where(and(eq(activityItems.chatId, chatId), eq(activityItems.userId, userId)))
    .orderBy(activityItems.messageId)
}

async function userBucketActivityUpdates(userId: number) {
  const rows = await db
    .select()
    .from(updates)
    .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, userId)))
    .orderBy(updates.seq)
  return rows
    .map((row) => UpdatesModel.decrypt(row).payload.update)
    .flatMap((update) => (update.oneofKind === "userUnreadActivity" ? [update.userUnreadActivity] : []))
}

const counts = (update: { unreadMentionsCount: number; unreadReactionsCount: number } | undefined) =>
  update ? [update.unreadMentionsCount, update.unreadReactionsCount] : undefined

describe("planMessageActivity", () => {
  const base = {
    chatType: "thread" as const,
    senderUserId: 1,
    countsAsUnread: true,
    isSystemMessage: false,
    mentionedUserIds: new Set<number>(),
    repliedToUserId: undefined,
    recipientUserIds: [1, 2, 3, 4],
    humanUserIds: new Set([1, 2, 3]),
  }

  test("mentions win over replies and each user gets one item", () => {
    expect(planMessageActivity({ ...base, mentionedUserIds: new Set([2]), repliedToUserId: 2 })).toEqual([
      { userId: 2, kind: ACTIVITY_KIND_MENTION },
    ])
    expect(planMessageActivity({ ...base, mentionedUserIds: new Set([2]), repliedToUserId: 3 })).toEqual([
      { userId: 2, kind: ACTIVITY_KIND_MENTION },
      { userId: 3, kind: ACTIVITY_KIND_REPLY },
    ])
  })

  test("skips the sender, bots, users without access, DMs, and quiet messages", () => {
    expect(planMessageActivity({ ...base, mentionedUserIds: new Set([1, 4, 9]) })).toEqual([])
    expect(planMessageActivity({ ...base, repliedToUserId: 1 })).toEqual([])
    expect(planMessageActivity({ ...base, chatType: "private", mentionedUserIds: new Set([2]) })).toEqual([])
    expect(planMessageActivity({ ...base, countsAsUnread: false, mentionedUserIds: new Set([2]) })).toEqual([])
    expect(planMessageActivity({ ...base, isSystemMessage: true, mentionedUserIds: new Set([2]) })).toEqual([])
  })
})

describe("activity items", () => {
  setupTestLifecycle()

  test("a mention and a reply create items, durable updates and dialog counts", async () => {
    const { alice, bob, carol, chat, peer, as } = await threadFixture()
    await send(peer, as(bob), { message: "first from bob" })
    await send(peer, as(alice), { message: "@bob look", entities: mention(bob.id) })
    await send(peer, as(carol), { message: "agreed", replyToMessageId: 1n })

    const bobRows = await rows(chat.id, bob.id)
    expect(bobRows.map((row) => [row.messageId, row.kind, row.actorUserId, row.readAt])).toEqual([
      [2, ACTIVITY_KIND_MENTION, alice.id, null],
      [3, ACTIVITY_KIND_REPLY, carol.id, null],
    ])
    expect(await rows(chat.id, alice.id)).toHaveLength(0)
    expect(await rows(chat.id, carol.id)).toHaveLength(0)

    // Replies count as mentions on the wire.
    const durable = await userBucketActivityUpdates(bob.id)
    expect(durable).toHaveLength(2)
    expect(counts(durable.at(-1))).toEqual([2, 0])
    expect(durable.at(-1)?.unreadMentionIds).toEqual([3n])

    const chats = await getChats({}, as(bob))
    const dialog = chats.dialogs.find((d) => d.chatId === BigInt(chat.id))
    expect([dialog?.unreadMentionsCount, dialog?.unreadReactionsCount]).toEqual([2, 0])

    // History pages flag what is still unread for the viewer.
    const history = await getChatHistory({ peerId: peer }, { currentUserId: bob.id, currentSessionId: 1 })
    const flags = history.messages
      .map((m) => [m.id, m.unreadMention ?? false, m.unreadReactions ?? false])
      .sort((a, b) => Number(a[0]) - Number(b[0]))
    expect(flags).toEqual([
      [1n, false, false],
      [2n, true, false],
      [3n, true, false],
    ])
  })

  test("bots and DMs get no items", async () => {
    const { alice, chat, peer, as } = await threadFixture()
    const bot = await user("bot")
    await db.update(users).set({ bot: true }).where(eq(users.id, bot.id))
    await testUtils.addParticipant(chat.id, bot.id)
    await send(peer, as(alice), { message: "@bot hi", entities: mention(bot.id) })
    expect(await rows(chat.id, bot.id)).toHaveLength(0)

    const dmPartner = await user("dm")
    const dm = await testUtils.createPrivateChat(alice, dmPartner)
    if (!dm) throw new Error("Missing DM")
    const dmPeer: InputPeer = { type: { oneofKind: "user", user: { userId: BigInt(dmPartner.id) } } }
    await send(dmPeer, as(alice), { message: "@dm hi", entities: mention(dmPartner.id) })
    expect(await rows(dm.id, dmPartner.id)).toHaveLength(0)
  })

  test("reading the chat leaves items; reading an item, mark all and Mark as Read clear them", async () => {
    const { alice, bob, chat, peer, as } = await threadFixture()
    for (let i = 0; i < 3; i++) await send(peer, as(alice), { message: "@bob", entities: mention(bob.id) })

    await readMessages({ peer }, as(bob))
    expect((await rows(chat.id, bob.id)).filter((row) => row.readAt === null)).toHaveLength(3)

    expect(await readActivity({ userId: bob.id, chat, messageIds: [1] })).toBe(1)
    const afterSingle = (await userBucketActivityUpdates(bob.id)).at(-1)
    expect(afterSingle?.clearedMessageIds).toEqual([1n])
    expect(counts(afterSingle)).toEqual([2, 0])

    // Already read elsewhere: nothing changes, but the read is echoed so a stale local row clears.
    expect(await readActivity({ userId: bob.id, chat, messageIds: [1] })).toBe(0)
    const echo = (await userBucketActivityUpdates(bob.id)).at(-1)
    expect(echo?.clearedMessageIds).toEqual([1n])
    expect(counts(echo)).toEqual([2, 0])

    await readActivity({ userId: bob.id, chat, allMentions: true, maxId: 2 })
    expect((await listUnreadActivity({ userId: bob.id, chatId: chat.id, reactions: false })).messageIds).toEqual([3])

    // A mention after the read point stays unread: Mark as Read is bounded like the cursor.
    await readMessages({ peer, readActivity: true, maxId: 3 }, as(bob))
    await send(peer, as(alice), { message: "@bob late", entities: mention(bob.id) })
    expect((await listUnreadActivity({ userId: bob.id, chatId: chat.id, reactions: false })).messageIds).toEqual([4])
    await readActivity({ userId: bob.id, chat, messageIds: [4] })

    await send(peer, as(alice), { message: "@bob last", entities: mention(bob.id) })
    const result = await readMessages({ peer, readActivity: true }, as(bob))
    // Activity changes travel through the user stream, never the RPC result.
    expect(result.updates.some((u) => u.update.oneofKind === "unreadActivity")).toBe(false)
    expect(counts((await userBucketActivityUpdates(bob.id)).at(-1))).toEqual([0, 0])
    const listed = await listUnreadActivity({ userId: bob.id, chatId: chat.id, reactions: false })
    expect(listed.messageIds).toHaveLength(0)
    expect(listed.counts).toEqual({ mentions: 0, reactions: 0 })
    // Read rows are kept for a future activity feed.
    expect((await rows(chat.id, bob.id)).every((row) => row.readAt !== null)).toBe(true)
  })

  test("deleting a message removes its items and tells the recipient", async () => {
    const { alice, bob, chat, peer, as } = await threadFixture()
    await send(peer, as(alice), { message: "@bob", entities: mention(bob.id) })
    await send(peer, as(alice), { message: "@bob again", entities: mention(bob.id) })

    await deleteMessage({ peer, messageIds: [1n] }, as(alice))
    expect((await rows(chat.id, bob.id)).map((row) => row.messageId)).toEqual([2])
    const last = (await userBucketActivityUpdates(bob.id)).at(-1)
    expect(last?.clearedMessageIds).toEqual([1n])
    expect(counts(last)).toEqual([1, 0])
  })

  test("listing pages oldest first", async () => {
    const { alice, bob, chat, peer, as } = await threadFixture()
    for (let i = 0; i < 3; i++) await send(peer, as(alice), { message: "@bob", entities: mention(bob.id) })
    const first = await listUnreadActivity({ userId: bob.id, chatId: chat.id, reactions: false, limit: 2 })
    expect(first.messageIds).toEqual([1, 2])
    expect(first.final).toBe(false)
    const next = await listUnreadActivity({ userId: bob.id, chatId: chat.id, reactions: false, offsetId: 2, limit: 2 })
    expect(next.messageIds).toEqual([3])
    expect(next.final).toBe(true)
  })

  test("reactions by others give the author one item that clears when the last unseen reaction goes", async () => {
    const { alice, bob, carol, chat, peer, as } = await threadFixture()
    await send(peer, as(bob), { message: "shipping it" })

    await addReaction({ emoji: "👍", messageId: 1n, peer }, as(bob))
    expect(await rows(chat.id, bob.id)).toHaveLength(0)

    await addReaction({ emoji: "🎉", messageId: 1n, peer }, as(alice))
    await addReaction({ emoji: "👍", messageId: 1n, peer }, as(carol))
    const items = await rows(chat.id, bob.id)
    expect(items.map((row) => [row.messageId, row.kind, row.actorUserId])).toEqual([[1, ACTIVITY_KIND_REACTION, carol.id]])
    const added = (await userBucketActivityUpdates(bob.id)).at(-1)
    expect(counts(added)).toEqual([0, 1])
    expect(added?.unreadReactionIds).toEqual([1n])
    expect((await getChatHistory({ peerId: peer }, { currentUserId: bob.id, currentSessionId: 1 })).messages[0]?.unreadReactions).toBe(true)

    // Carol's removal leaves Alice's unseen reaction, so the item stays.
    await deleteReaction({ emoji: "👍", messageId: 1n, peer }, as(carol))
    expect(await rows(chat.id, bob.id)).toHaveLength(1)
    await deleteReaction({ emoji: "🎉", messageId: 1n, peer }, as(alice))
    expect(await rows(chat.id, bob.id)).toHaveLength(0)
    const cleared = (await userBucketActivityUpdates(bob.id)).at(-1)
    expect(cleared?.clearedMessageIds).toEqual([1n])
    expect(counts(cleared)).toEqual([0, 0])
  })

  test("a reaction after the item was read makes it unread again", async () => {
    const { alice, bob, chat, peer, as } = await threadFixture()
    await send(peer, as(bob), { message: "hello" })
    await addReaction({ emoji: "👍", messageId: 1n, peer }, as(alice))
    await readActivity({ userId: bob.id, chat, messageIds: [1] })
    expect((await rows(chat.id, bob.id))[0]?.readAt).not.toBeNull()

    await addReaction({ emoji: "🎉", messageId: 1n, peer }, as(alice))
    const [row] = await rows(chat.id, bob.id)
    expect(row?.readAt).toBeNull()
    const listed = await listUnreadActivity({ userId: bob.id, chatId: chat.id, reactions: true })
    expect(listed.messageIds).toEqual([1])
    expect(listed.counts.reactions).toBe(1)
  })

  test("DM reactions count and never touch the chat sequence", async () => {
    const alice = await user("dm-alice"), bob = await user("dm-bob")
    const dm = await testUtils.createPrivateChat(alice, bob)
    if (!dm) throw new Error("Missing DM")
    const bobPeer: InputPeer = { type: { oneofKind: "user", user: { userId: BigInt(bob.id) } } }
    const alicePeer: InputPeer = { type: { oneofKind: "user", user: { userId: BigInt(alice.id) } } }
    await send(alicePeer, testUtils.functionContext({ userId: bob.id, sessionId: 1 }), { message: "hi" })
    await addReaction({ emoji: "❤️", messageId: 1n, peer: bobPeer }, testUtils.functionContext({ userId: alice.id, sessionId: 1 }))
    expect((await rows(dm.id, bob.id)).map((row) => row.kind)).toEqual([ACTIVITY_KIND_REACTION])

    const chatUpdates = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, dm.id)))
      .orderBy(updates.seq)
    // Reactions stay ephemeral in the chat bucket (server: keep reactions ephemeral).
    const kinds = chatUpdates.map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)
    expect(kinds).not.toContain("reaction")
  })
})
