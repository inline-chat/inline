import { describe, expect, spyOn, test } from "bun:test"
import { and, eq, sql } from "drizzle-orm"
import { MessageEntity_Type as T, type InputPeer, type MessageEntities, type Update } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import {
  ACTIVITY_KIND_MENTION,
  ACTIVITY_KIND_REACTION,
  ACTIVITY_KIND_REPLY,
  activityItems,
  messages,
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
import { RealtimeUpdates } from "@in/server/realtime/message"
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

async function holdUserSequence(userId: number) {
  const entered = Promise.withResolvers<void>()
  const released = Promise.withResolvers<void>()
  const transaction = db.transaction(async (tx) => {
    // This blocks sequence allocation but permits activity's foreign-key KEY SHARE lock.
    await tx.select({ id: users.id }).from(users).where(eq(users.id, userId)).for("no key update")
    entered.resolve()
    await released.promise
  })
  await entered.promise
  return { transaction, release: released.resolve }
}

async function waitForActivityMutationWaiters(minimum: number) {
  const deadline = Date.now() + 5_000
  while (Date.now() < deadline) {
    const rows = await db.execute<{ count: number }>(sql`
      SELECT count(*)::int AS count FROM pg_stat_activity
      WHERE datname = current_database() AND pid <> pg_backend_pid()
        AND wait_event_type = 'Lock'
        AND (query ILIKE '%users%' OR query ILIKE '%chats%')
    `)
    if (Number(rows[0]?.count ?? 0) >= minimum) return
    await Bun.sleep(5)
  }
  throw new Error(`Timed out waiting for ${minimum} activity mutation lock waiters`)
}

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

  test("concurrent mention creation publishes the count after both mutations", async () => {
    const { alice, bob, carol, chat, peer, as } = await threadFixture()
    const hold = await holdUserSequence(bob.id)
    const sends = [
      send(peer, as(alice), { message: "@bob one", entities: mention(bob.id) }),
      send(peer, as(carol), { message: "@bob two", entities: mention(bob.id) }),
    ]
    try {
      await waitForActivityMutationWaiters(2)
    } finally {
      hold.release()
      await hold.transaction
      await Promise.allSettled(sends)
    }
    await Promise.all(sends)
    expect((await rows(chat.id, bob.id)).filter((row) => row.readAt === null)).toHaveLength(2)
    expect(counts((await userBucketActivityUpdates(bob.id)).at(-1))).toEqual([2, 0])
  })

  test("concurrent reads cannot leave a stale nonzero durable count", async () => {
    const { alice, bob, chat, peer, as } = await threadFixture()
    await send(peer, as(alice), { message: "@bob one", entities: mention(bob.id) })
    await send(peer, as(alice), { message: "@bob two", entities: mention(bob.id) })
    const hold = await holdUserSequence(bob.id)
    const reads = [1, 2].map((id) => readActivity({ userId: bob.id, chat, messageIds: [id] }))
    try {
      await waitForActivityMutationWaiters(2)
    } finally {
      hold.release()
      await hold.transaction
      await Promise.allSettled(reads)
    }
    await Promise.all(reads)
    expect((await rows(chat.id, bob.id)).every((row) => row.readAt !== null)).toBe(true)
    expect(counts((await userBucketActivityUpdates(bob.id)).at(-1))).toEqual([0, 0])
  })

  test("a recipient reading during first message publication cannot regain unread activity afterward", async () => {
    const { alice, bob, chat, peer, as } = await threadFixture()
    const originalPush = RealtimeUpdates.pushToUser.bind(RealtimeUpdates)
    let unreadAtFirstPublication: number | undefined
    const liveActivity: Update[] = []
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async (userId, updates, options) => {
      if (userId === bob.id) liveActivity.push(...updates.filter((update) => update.update.oneofKind === "unreadActivity"))
      if (userId === bob.id && updates.some((update) => update.update.oneofKind === "newMessage")) {
        unreadAtFirstPublication = (await rows(chat.id, bob.id)).filter((row) => row.readAt === null).length
        await readActivity({ userId: bob.id, chat, messageIds: [1] })
      }
      return await originalPush(userId, updates, options)
    })
    try {
      await send(peer, as(alice), { message: "@bob", entities: mention(bob.id) })
      expect(unreadAtFirstPublication).toBe(1)
      expect((await rows(chat.id, bob.id)).map((row) => row.readAt !== null)).toEqual([true])
      expect(counts((await userBucketActivityUpdates(bob.id)).at(-1))).toEqual([0, 0])
      // The create hint is sent after the fast read hint. Both carry their
      // durable user sequence, so the client can reject the late older count.
      expect(liveActivity).toHaveLength(2)
      expect(liveActivity.every((update) => update.seq !== undefined && update.seq > 0 && update.date !== undefined)).toBe(true)
      expect(liveActivity[0]!.seq).toBeGreaterThan(liveActivity[1]!.seq!)
    } finally {
      push.mockRestore()
    }
  })

  test("activity persistence failure rolls back the message and its chat update", async () => {
    const { alice, bob, chat, peer, as } = await threadFixture()
    await db.execute(sql`
      CREATE FUNCTION reject_activity_insert() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'activity write fault'; END $$
    `)
    try {
      await db.execute(sql`
        CREATE TRIGGER reject_activity_insert BEFORE INSERT ON activity_items
        FOR EACH ROW EXECUTE FUNCTION reject_activity_insert()
      `)
      await expect(sendMessage({ peerId: peer, message: "@bob", entities: mention(bob.id) }, as(alice))).rejects.toThrow()
      expect(await db.select().from(messages).where(eq(messages.chatId, chat.id))).toHaveLength(0)
      expect(await rows(chat.id, bob.id)).toHaveLength(0)
      expect(await db.select().from(updates).where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, chat.id)))).toHaveLength(0)
    } finally {
      await db.execute(sql`DROP TRIGGER IF EXISTS reject_activity_insert ON activity_items`)
      await db.execute(sql`DROP FUNCTION reject_activity_insert()`)
    }
  })

  test("competing read, reaction and deletion leave the final durable counters authoritative", async () => {
    const { alice, bob, chat, peer, as } = await threadFixture()
    await send(peer, as(bob), { message: "my message" })
    await send(peer, as(alice), { message: "@bob", entities: mention(bob.id) })
    const mutations = await Promise.allSettled([
      readActivity({ userId: bob.id, chat, allMentions: true, allReactions: true, maxId: 2 }),
      addReaction({ emoji: "👍", messageId: 1n, peer }, as(alice)),
      deleteMessage({ peer, messageIds: [2n] }, as(alice)),
    ])
    for (const mutation of mutations) expect(mutation.status).toBe("fulfilled")
    const unread = (await rows(chat.id, bob.id)).filter((row) => row.readAt === null)
    expect(counts((await userBucketActivityUpdates(bob.id)).at(-1))).toEqual([
      unread.filter((row) => row.kind !== ACTIVITY_KIND_REACTION).length,
      unread.filter((row) => row.kind === ACTIVITY_KIND_REACTION).length,
    ])
  })

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
