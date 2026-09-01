import { chats, type DbChat } from "@in/server/db/schema"
import { db } from "@in/server/db"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { hasThreadAccessGrant } from "@in/server/modules/authorization/threadAccess"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { resolveChatPermissions } from "@in/server/modules/authorization/chatPermissions"
import type { Transaction } from "@in/server/db/types"
import { getCurrentSpaceMembership } from "@in/server/modules/authorization/spaceMembershipLifecycle"
import { eq } from "drizzle-orm"

type AccessQuery = Pick<typeof db, "select"> | Pick<Transaction, "select">

export const AccessGuards = {
  ensureChatAccess,
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
