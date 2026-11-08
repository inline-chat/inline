import { chatParticipants, chats, users, type DbChat } from "@in/server/db/schema"
import { db } from "@in/server/db"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { hasThreadAccessGrant } from "@in/server/modules/authorization/threadAccess"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { resolveChatPermissions } from "@in/server/modules/authorization/chatPermissions"
import type { Transaction } from "@in/server/db/types"
import { getCurrentSpaceMembership } from "@in/server/modules/authorization/spaceMembershipLifecycle"
import { and, eq, inArray, isNull, or } from "drizzle-orm"

type AccessQuery = Pick<typeof db, "select"> | Pick<Transaction, "select">

export const AccessGuards = {
  ensureChatAccess,
  ensureChatReadAccess,
  hasChatAccess,
  ensureChatInfoEditAccess,
  ensureSpaceMember,
}

// TODO: this can all be optimized to use less queries and be smarter about caching with a simpler API.

async function ensureChatAccess(chat: DbChat, userId: number, query: AccessQuery = db) {
  if (chat.type === "private") {
    if (chat.minUserId !== userId && chat.maxUserId !== userId) {
      throw RealtimeRpcError.PeerIdInvalid()
    }
    return
  }

  // A retained participant/group row is cached projection, not independent
  // authority for a Space-scoped chat. Fence it with the current nondeleted
  // Space membership before accepting any direct grant.
  const validatedSpaceId = await ensureOwningSpaceMembership(chat, userId, query)

  if (await hasThreadAccessGrant(chat.id, userId, query)) {
    return
  }

  if (chat.parentChatId != null) {
    const parentChat = await getChatByIdFrom(chat.parentChatId, query)
    if (!parentChat) {
      throw RealtimeRpcError.PeerIdInvalid()
    }

    await ensureInheritedChatAccess(parentChat, userId, validatedSpaceId, query)
    return
  }

  await ensureTopLevelChatAccess(chat, userId, validatedSpaceId, query)
}

/**
 * `ensureChatAccess` as a boolean: false when access is denied, while database
 * failures still throw. Use it to gate authority such as thread-creator rights
 * on the user's current access, since `createdBy` alone outlives removal.
 */
async function hasChatAccess(chat: DbChat, userId: number, query: AccessQuery = db): Promise<boolean> {
  try {
    await ensureChatAccess(chat, userId, query)
    return true
  } catch (error) {
    if (error instanceof RealtimeRpcError) return false
    throw error
  }
}

const MAX_CHAT_DEPTH = 8

/**
 * Read-only access for opening a chat: the person's own access, or else the
 * access of a bot they manage that is directly in this chat or a chat above it
 * (a participant, or the DM peer). The bot runs on its owner's machine, which
 * already sees what the bot sees. Space-wide public access through the bot
 * doesn't count, and neither do the bot's DMs themselves (threads under them
 * do). Use only where a person opens and reads; every write keeps
 * `ensureChatAccess`, so owners read and approve but don't post or manage.
 * Returns the bot when access came through it.
 */
async function ensureChatReadAccess(chat: DbChat, userId: number, query: AccessQuery = db): Promise<number | undefined> {
  try {
    await ensureChatAccess(chat, userId, query)
    return undefined
  } catch (error) {
    // DMs are addressed by the other person, so a third party can't open one.
    if (!(error instanceof RealtimeRpcError) || chat.type === "private") throw error
    for (const botUserId of await managedBotsDirectlyIn(chat, userId, query)) {
      if (await hasChatAccess(chat, botUserId, query)) return botUserId
    }
    throw error
  }
}

/** Bots `userId` manages that are a participant or the DM peer of `chat` or an ancestor. */
async function managedBotsDirectlyIn(chat: DbChat, userId: number, query: AccessQuery): Promise<number[]> {
  const managed = await query
    .select({ id: users.id })
    .from(users)
    .where(and(eq(users.botCreatorId, userId), eq(users.bot, true), or(isNull(users.deleted), eq(users.deleted, false))))
  if (managed.length === 0) return []
  const managedIds = new Set(managed.map((row) => row.id))

  const found = new Set<number>()
  const threadIds: number[] = []
  let current: DbChat | undefined = chat
  for (let depth = 0; current && depth < MAX_CHAT_DEPTH; depth++) {
    if (current.type === "private") {
      for (const peer of [current.minUserId, current.maxUserId]) {
        if (peer != null && managedIds.has(peer)) found.add(peer)
      }
    } else {
      threadIds.push(current.id)
    }
    current = current.parentChatId == null ? undefined : await getChatByIdFrom(current.parentChatId, query)
  }
  if (threadIds.length > 0) {
    const rows = await query
      .select({ userId: chatParticipants.userId })
      .from(chatParticipants)
      .where(and(inArray(chatParticipants.chatId, threadIds), inArray(chatParticipants.userId, [...managedIds])))
    for (const row of rows) found.add(row.userId)
  }
  return [...found]
}

async function ensureChatInfoEditAccess(chat: DbChat, userId: number, query?: Pick<Transaction, "select">) {
  await ensureOwningSpaceMembership(chat, userId, query ?? db)
  const permissions = await resolveChatPermissions(chat, userId, query)
  if (!permissions.canUpdateInfo) {
    throw RealtimeRpcError.PeerIdInvalid()
  }
}

async function ensureInheritedChatAccess(
  chat: DbChat,
  userId: number,
  validatedSpaceId: number | undefined,
  query: AccessQuery,
) {
  if (chat.parentChatId != null) {
    const parentChat = await getChatByIdFrom(chat.parentChatId, query)
    if (!parentChat) {
      throw RealtimeRpcError.PeerIdInvalid()
    }

    await ensureInheritedChatAccess(parentChat, userId, validatedSpaceId, query)
    return
  }

  await ensureTopLevelChatAccess(chat, userId, validatedSpaceId, query)
}

async function ensureTopLevelChatAccess(
  chat: DbChat,
  userId: number,
  validatedSpaceId: number | undefined,
  query: AccessQuery,
) {
  if (chat.type === "private") {
    if (chat.minUserId !== userId && chat.maxUserId !== userId) {
      throw RealtimeRpcError.PeerIdInvalid()
    }
    return
  }

  if (!chat.spaceId) {
    await ensureThreadAccessGrant(chat.id, userId, query)
    return
  }

  if (validatedSpaceId !== chat.spaceId) {
    await ensureSpaceMember(chat.spaceId, userId, query)
  }

  if (chat.publicThread) {
    const member = await getCurrentSpaceMembership(chat.spaceId, userId, query)
    if (!member || member.canAccessPublicChats === false) {
      throw RealtimeRpcError.PeerIdInvalid()
    }
    return
  }

  await ensureThreadAccessGrant(chat.id, userId, query)
}

async function ensureOwningSpaceMembership(
  chat: DbChat,
  userId: number,
  query: AccessQuery,
): Promise<number | undefined> {
  if (chat.spaceId != null) {
    await ensureSpaceMember(chat.spaceId, userId, query)
    return chat.spaceId
  }
  if (chat.parentChatId == null) return undefined

  const parentChat = await getChatByIdFrom(chat.parentChatId, query)
  if (!parentChat) throw RealtimeRpcError.PeerIdInvalid()
  return ensureOwningSpaceMembership(parentChat, userId, query)
}

async function ensureSpaceMember(spaceId: number, userId: number, query: AccessQuery = db) {
  // Positive process-local caches cannot prove current authority after a
  // removal or soft delete committed on another server process.
  const member = await getCurrentSpaceMembership(spaceId, userId, query)
  if (member) {
    AccessGuardsCache.setSpaceMember(spaceId, userId)
  }

  if (!member) {
    AccessGuardsCache.resetSpaceMember(spaceId, userId)
    throw RealtimeRpcError.SpaceIdInvalid()
  }
}

async function ensureThreadAccessGrant(chatId: number, userId: number, query: AccessQuery) {
  const exists = await hasThreadAccessGrant(chatId, userId, query)
  if (!exists) {
    throw RealtimeRpcError.PeerIdInvalid()
  }
}

async function getChatByIdFrom(chatId: number, query: AccessQuery): Promise<DbChat | undefined> {
  const [chat] = await query.select().from(chats).where(eq(chats.id, chatId)).limit(1)
  return chat
}
