import { and, eq, gt, gte, inArray, isNull, lt, lte, ne, or, sql } from "drizzle-orm"
import type { Message, Update, UpdateUnreadActivity } from "@inline-chat/protocol/core"
import type { ServerUpdate } from "@in/server/protocol/server"
import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import {
  ACTIVITY_KIND_MENTION,
  ACTIVITY_KIND_REACTION,
  ACTIVITY_KIND_REPLY,
  activityItems,
  chats,
  messages,
  reactions,
  users,
  type DbActivityKind,
  type DbChat,
} from "@in/server/db/schema"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeOutputPeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import { registerPostCommitHook } from "@in/server/db/commitHooks"

const log = new Log("activityItems")

export const ACTIVITY_LIST_LIMIT = 500

type ChatForActivity = Pick<DbChat, "id" | "type" | "minUserId" | "maxUserId">

type ChangedRow = { userId: number; messageId: number; kind: DbActivityKind }

/** Per-dialog unread counters as the wire shows them: replies count as mentions. */
export type ActivityCounts = { mentions: number; reactions: number }

export const emptyActivityCounts = (): ActivityCounts => ({ mentions: 0, reactions: 0 })

const MENTION_KINDS: DbActivityKind[] = [ACTIVITY_KIND_MENTION, ACTIVITY_KIND_REPLY]

const isMentionKind = (kind: DbActivityKind) => kind !== ACTIVITY_KIND_REACTION

// ------------------------------------------------------------
// Creation rules
// ------------------------------------------------------------

/**
 * Who gets a mention or reply item for a new message. Pure so the rules are testable.
 *
 * - DMs never get mention or reply items: every DM message is already addressed to the viewer.
 * - A message that both mentions and replies to someone counts once, as a mention.
 * - Only users who can see the chat, never the sender, and never bots.
 */
export function planMessageActivity(input: {
  chatType: DbChat["type"]
  senderUserId: number
  countsAsUnread: boolean
  isSystemMessage: boolean
  mentionedUserIds: ReadonlySet<number>
  repliedToUserId: number | undefined
  recipientUserIds: readonly number[]
  humanUserIds: ReadonlySet<number>
}): { userId: number; kind: DbActivityKind }[] {
  if (input.chatType === "private") return []
  if (!input.countsAsUnread || input.isSystemMessage) return []

  const eligible = new Set(
    input.recipientUserIds.filter((userId) => userId !== input.senderUserId && input.humanUserIds.has(userId)),
  )
  const planned = new Map<number, DbActivityKind>()
  for (const userId of input.mentionedUserIds) {
    if (eligible.has(userId)) planned.set(userId, ACTIVITY_KIND_MENTION)
  }
  if (input.repliedToUserId !== undefined && eligible.has(input.repliedToUserId) && !planned.has(input.repliedToUserId)) {
    planned.set(input.repliedToUserId, ACTIVITY_KIND_REPLY)
  }
  return Array.from(planned, ([userId, kind]) => ({ userId, kind }))
}

async function getHumanUserIds(userIds: number[]): Promise<Set<number>> {
  const unique = Array.from(new Set(userIds.filter((id) => Number.isSafeInteger(id) && id > 0)))
  if (unique.length === 0) return new Set()
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(
      and(
        inArray(users.id, unique),
        sql`${users.bot} is not true`,
        sql`${users.deleted} is not true`,
      ),
    )
  return new Set(rows.map((row) => row.id))
}

/** Records mention and reply items for a sent message and notifies each recipient. */
export async function recordMessageActivity(input: {
  chat: ChatForActivity
  message: { messageId: number; fromId: number; countsAsUnread: boolean; isSystemMessage: boolean }
  mentionedUserIds: ReadonlySet<number>
  repliedToUserId: number | undefined
  recipientUserIds: readonly number[]
}): Promise<void> {
  if (input.chat.type === "private") return

  const candidates = [...input.mentionedUserIds, ...(input.repliedToUserId === undefined ? [] : [input.repliedToUserId])]
  if (candidates.length === 0) return

  const humanUserIds = await getHumanUserIds(candidates)
  const planned = planMessageActivity({
    chatType: input.chat.type,
    senderUserId: input.message.fromId,
    countsAsUnread: input.message.countsAsUnread,
    isSystemMessage: input.message.isSystemMessage,
    mentionedUserIds: input.mentionedUserIds,
    repliedToUserId: input.repliedToUserId,
    recipientUserIds: input.recipientUserIds,
    humanUserIds,
  })
  if (planned.length === 0) return

  const updatesByUser = await db.transaction(async (tx) => {
    const inserted = await tx
      .insert(activityItems)
      .values(
        planned.map(({ userId, kind }) => ({
          userId,
          chatId: input.chat.id,
          messageId: input.message.messageId,
          kind,
          actorUserId: input.message.fromId,
        })),
      )
      .onConflictDoNothing()
      .returning({ userId: activityItems.userId, messageId: activityItems.messageId, kind: activityItems.kind })

    return await enqueueChanges(tx, input.chat, { added: inserted, removed: [] })
  })

  pushChanges(updatesByUser)
}

/**
 * Someone else reacted to a message: its author gets (or regains) one unread reaction item.
 * `date` keeps the first unseen reaction so removing one reaction can tell whether others remain.
 * Runs inside the reaction transaction, after the chat row lock.
 */
export async function recordReactionActivity(
  tx: Transaction,
  input: { chat: ChatForActivity; messageId: number; reactorUserId: number },
): Promise<void> {
  const [message] = await tx
    .select({ fromId: messages.fromId })
    .from(messages)
    .where(and(eq(messages.chatId, input.chat.id), eq(messages.messageId, input.messageId)))
    .limit(1)
  if (!message || message.fromId === input.reactorUserId) return

  const [author] = await tx
    .select({ id: users.id })
    .from(users)
    .where(and(eq(users.id, message.fromId), sql`${users.bot} is not true`, sql`${users.deleted} is not true`))
    .limit(1)
  if (!author) return

  const [row] = await tx
    .insert(activityItems)
    .values({
      userId: author.id,
      chatId: input.chat.id,
      messageId: input.messageId,
      kind: ACTIVITY_KIND_REACTION,
      actorUserId: input.reactorUserId,
    })
    .onConflictDoUpdate({
      target: [activityItems.userId, activityItems.chatId, activityItems.kind, activityItems.messageId],
      set: {
        actorUserId: input.reactorUserId,
        date: sql`CASE WHEN ${activityItems.readAt} IS NULL THEN ${activityItems.date} ELSE now() END`,
        readAt: null,
      },
    })
    .returning({ userId: activityItems.userId, messageId: activityItems.messageId, kind: activityItems.kind })
  if (!row) return
  pushAfterCommit(tx, await enqueueChanges(tx, input.chat, { added: [row], removed: [] }))
}

/**
 * A reaction was removed. The author's unread reaction item goes away only when no reaction
 * by someone else since the item became unread is left on the message.
 */
export async function removeStaleReactionActivity(
  tx: Transaction,
  input: { chat: ChatForActivity; messageId: number },
): Promise<void> {
  const [message] = await tx
    .select({ fromId: messages.fromId })
    .from(messages)
    .where(and(eq(messages.chatId, input.chat.id), eq(messages.messageId, input.messageId)))
    .limit(1)
  if (!message) return

  const [item] = await tx
    .select({ date: activityItems.date })
    .from(activityItems)
    .where(
      and(
        eq(activityItems.userId, message.fromId),
        eq(activityItems.chatId, input.chat.id),
        eq(activityItems.kind, ACTIVITY_KIND_REACTION),
        eq(activityItems.messageId, input.messageId),
        isNull(activityItems.readAt),
      ),
    )
    .limit(1)
  if (!item) return

  const [remaining] = await tx
    .select({ id: reactions.id })
    .from(reactions)
    .where(
      and(
        eq(reactions.chatId, input.chat.id),
        eq(reactions.messageId, input.messageId),
        ne(reactions.userId, message.fromId),
        gte(reactions.date, item.date),
      ),
    )
    .limit(1)
  if (remaining) return

  const deleted = await tx
    .delete(activityItems)
    .where(
      and(
        eq(activityItems.userId, message.fromId),
        eq(activityItems.chatId, input.chat.id),
        eq(activityItems.kind, ACTIVITY_KIND_REACTION),
        eq(activityItems.messageId, input.messageId),
      ),
    )
    .returning({ userId: activityItems.userId, messageId: activityItems.messageId, kind: activityItems.kind })
  pushAfterCommit(tx, await enqueueChanges(tx, input.chat, { added: [], removed: deleted }))
}

// ------------------------------------------------------------
// Counts and listing
// ------------------------------------------------------------

export async function getActivityCountsForChats({
  userId,
  chatIds,
  tx,
}: {
  userId: number
  chatIds: readonly number[]
  tx?: Transaction
}): Promise<Map<number, ActivityCounts>> {
  const result = new Map<number, ActivityCounts>()
  for (const chatId of chatIds) result.set(chatId, emptyActivityCounts())
  if (chatIds.length === 0) return result

  const rows = await (tx ?? db)
    .select({
      chatId: activityItems.chatId,
      mentions: sql<number>`count(*) filter (where ${activityItems.kind} <> ${ACTIVITY_KIND_REACTION})::int`,
      reactions: sql<number>`count(*) filter (where ${activityItems.kind} = ${ACTIVITY_KIND_REACTION})::int`,
    })
    .from(activityItems)
    .where(
      and(
        eq(activityItems.userId, userId),
        inArray(activityItems.chatId, Array.from(new Set(chatIds))),
        isNull(activityItems.readAt),
      ),
    )
    .groupBy(activityItems.chatId)

  for (const row of rows) {
    result.set(row.chatId, { mentions: row.mentions, reactions: row.reactions })
  }
  return result
}

export async function getActivityCounts(userId: number, chatId: number, tx?: Transaction): Promise<ActivityCounts> {
  const counts = await getActivityCountsForChats({ userId, chatIds: [chatId], tx })
  return counts.get(chatId) ?? emptyActivityCounts()
}

/** IDs of unread mentions (and replies), or of the user's messages with unread reactions, oldest first. */
export async function listUnreadActivity(input: {
  userId: number
  chatId: number
  reactions: boolean
  offsetId?: number
  limit?: number
}): Promise<{ messageIds: number[]; counts: ActivityCounts; final: boolean }> {
  const limit = Math.min(Math.max(input.limit ?? ACTIVITY_LIST_LIMIT, 1), ACTIVITY_LIST_LIMIT)
  const rows = await db
    .selectDistinct({ messageId: activityItems.messageId })
    .from(activityItems)
    .where(
      and(
        eq(activityItems.userId, input.userId),
        eq(activityItems.chatId, input.chatId),
        isNull(activityItems.readAt),
        input.reactions ? eq(activityItems.kind, ACTIVITY_KIND_REACTION) : inArray(activityItems.kind, MENTION_KINDS),
        input.offsetId === undefined ? undefined : gt(activityItems.messageId, input.offsetId),
      ),
    )
    .orderBy(activityItems.messageId)
    .limit(limit + 1)

  return {
    messageIds: rows.slice(0, limit).map((row) => row.messageId),
    counts: await getActivityCounts(input.userId, input.chatId),
    final: rows.length <= limit,
  }
}

/**
 * Sets `unreadMention` and `unreadReactions` on encoded history messages. One indexed lookup per page.
 */
export async function applyUnreadActivityFlags(input: {
  userId: number
  chatId: number
  messages: Message[]
  tx?: Transaction
}): Promise<void> {
  if (input.messages.length === 0) return
  const rows = await (input.tx ?? db)
    .select({ messageId: activityItems.messageId, kind: activityItems.kind })
    .from(activityItems)
    .where(
      and(
        eq(activityItems.userId, input.userId),
        eq(activityItems.chatId, input.chatId),
        isNull(activityItems.readAt),
        inArray(
          activityItems.messageId,
          input.messages.map((message) => Number(message.id)),
        ),
      ),
    )
  if (rows.length === 0) return

  const byId = new Map(input.messages.map((message) => [Number(message.id), message]))
  for (const row of rows) {
    const message = byId.get(row.messageId)
    if (!message) continue
    if (isMentionKind(row.kind)) message.unreadMention = true
    else message.unreadReactions = true
  }
}

// ------------------------------------------------------------
// Reading and removal
// ------------------------------------------------------------

/**
 * Reads mentions and reactions and tells every session of the user, the caller included, through
 * the ordered user stream. Nothing is returned to the caller on purpose: counts delivered out of
 * order with that stream would double-subtract reads still in flight on the device.
 *
 * Message IDs are echoed as cleared even when nothing changed, so a device holding a stale
 * unread row (read elsewhere while a history page was in flight) drops it on the same stream.
 * Returns how many rows changed.
 */
export async function readActivity(input: {
  userId: number
  chat: ChatForActivity
  messageIds?: readonly number[]
  allMentions?: boolean
  allReactions?: boolean
  maxId?: number
}): Promise<number> {
  const messageIds = Array.from(new Set((input.messageIds ?? []).filter((id) => Number.isSafeInteger(id) && id > 0)))
  const allKinds: DbActivityKind[] = []
  if (input.allMentions) allKinds.push(...MENTION_KINDS)
  if (input.allReactions) allKinds.push(ACTIVITY_KIND_REACTION)
  if (messageIds.length === 0 && allKinds.length === 0) return 0

  const changes = await db.transaction(async (tx) => {
    const base = and(eq(activityItems.userId, input.userId), eq(activityItems.chatId, input.chat.id), isNull(activityItems.readAt))
    const bySeen = messageIds.length === 0 ? undefined : and(base, inArray(activityItems.messageId, messageIds))
    const byAll =
      allKinds.length === 0
        ? undefined
        : and(
            base,
            inArray(activityItems.kind, allKinds),
            input.maxId === undefined ? undefined : lte(activityItems.messageId, input.maxId),
          )
    const read = await tx
      .update(activityItems)
      .set({ readAt: sql`now()` })
      .where(or(bySeen, byAll))
      .returning({ userId: activityItems.userId, messageId: activityItems.messageId, kind: activityItems.kind })

    if (read.length === 0 && messageIds.length === 0) return { changed: 0, updates: new Map() as ActivityChanges }
    const echoed = messageIds.map((messageId) => ({ userId: input.userId, messageId }))
    return { changed: read.length, updates: await enqueueChanges(tx, input.chat, { added: [], removed: [...read, ...echoed] }) }
  })

  pushChanges(changes.updates)
  return changes.changed
}

/**
 * Deletes every activity row for messages that are about to be deleted and tells each affected
 * user. Call inside the deleting transaction, before the messages are removed.
 */
export async function removeActivityForMessages(
  tx: Transaction,
  input: { chat: ChatForActivity; messageIds: readonly number[] },
): Promise<ActivityChanges> {
  const messageIds = Array.from(new Set(input.messageIds))
  if (messageIds.length === 0) return new Map()

  const deleted = await tx
    .delete(activityItems)
    .where(and(eq(activityItems.chatId, input.chat.id), inArray(activityItems.messageId, messageIds)))
    .returning({
      userId: activityItems.userId,
      messageId: activityItems.messageId,
      kind: activityItems.kind,
      readAt: activityItems.readAt,
    })

  // Read rows were already removed from every client.
  const unread = deleted.filter((row) => row.readAt === null)
  const changes = await enqueueChanges(tx, input.chat, { added: [], removed: unread })
  pushAfterCommit(tx, changes)
  return changes
}

/** Same as removeActivityForMessages for a whole-history clear, optionally only before a date. */
export async function removeActivityForChatHistory(
  tx: Transaction,
  input: { chatId: number; beforeDate: Date | undefined },
): Promise<void> {
  const [chat] = await tx
    .select({ id: chats.id, type: chats.type, minUserId: chats.minUserId, maxUserId: chats.maxUserId })
    .from(chats)
    .where(eq(chats.id, input.chatId))
    .limit(1)
  if (!chat) return

  const clearedMessageIds = tx
    .select({ messageId: messages.messageId })
    .from(messages)
    .where(
      input.beforeDate
        ? and(eq(messages.chatId, input.chatId), lt(messages.date, input.beforeDate))
        : eq(messages.chatId, input.chatId),
    )
  const deleted = await tx
    .delete(activityItems)
    .where(and(eq(activityItems.chatId, input.chatId), inArray(activityItems.messageId, clearedMessageIds)))
    .returning({
      userId: activityItems.userId,
      messageId: activityItems.messageId,
      kind: activityItems.kind,
      readAt: activityItems.readAt,
    })
  const unread = deleted.filter((row) => row.readAt === null)
  pushAfterCommit(tx, await enqueueChanges(tx, chat, { added: [], removed: unread }))
}

// ------------------------------------------------------------
// Durable fan-out
// ------------------------------------------------------------

export type ActivityChanges = Map<number, UpdateUnreadActivity>

async function enqueueChanges(
  tx: Transaction,
  chat: ChatForActivity,
  changes: { added: ChangedRow[]; removed: { userId: number; messageId: number }[] },
): Promise<ActivityChanges> {
  const userIds = Array.from(
    new Set([...changes.added.map((row) => row.userId), ...changes.removed.map((row) => row.userId)]),
  ).sort((a, b) => a - b)
  const result: ActivityChanges = new Map()
  if (userIds.length === 0) return result

  for (const userId of userIds) {
    const counts = await getActivityCounts(userId, chat.id, tx)
    const added = changes.added.filter((row) => row.userId === userId)
    result.set(userId, {
      peerId: encodeOutputPeerFromChat(chat as DbChat, { currentUserId: userId }),
      unreadMentionsCount: counts.mentions,
      unreadReactionsCount: counts.reactions,
      unreadMentionIds: sortedIds(added.filter((row) => isMentionKind(row.kind))),
      unreadReactionIds: sortedIds(added.filter((row) => !isMentionKind(row.kind))),
      clearedMessageIds: sortedIds(changes.removed.filter((row) => row.userId === userId)),
    })
  }

  await UserBucketUpdates.enqueueMany(
    userIds.map((userId) => ({
      userId,
      update: { oneofKind: "userUnreadActivity", userUnreadActivity: result.get(userId)! } satisfies ServerUpdate["update"],
    })),
    { tx },
  )
  return result
}

function sortedIds(rows: readonly { messageId: number }[]): bigint[] {
  return Array.from(new Set(rows.map((row) => row.messageId)))
    .sort((a, b) => a - b)
    .map(BigInt)
}

function pushAfterCommit(tx: Transaction, changes: ActivityChanges): void {
  if (changes.size === 0) return
  registerPostCommitHook(tx, Symbol("activity-items-push"), {
    run: async () => pushChanges(changes),
  })
}

/** Realtime delivery after commit. Durable catch-up covers anything this misses. */
export function pushChanges(changes: ActivityChanges): void {
  for (const [userId, unreadActivity] of changes) {
    const realtime: Update = { update: { oneofKind: "unreadActivity", unreadActivity } }
    RealtimeUpdates.pushToUser(userId, [realtime]).catch((error) => {
      log.warn("Failed to push activity update", { userId, error })
    })
  }
}
