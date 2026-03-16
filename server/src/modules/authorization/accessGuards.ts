import type { DbChat } from "@in/server/db/schema"
import { MembersModel } from "@in/server/db/models/members"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { db } from "@in/server/db"
import { chatParticipants } from "@in/server/db/schema/chats"
import { and, eq } from "drizzle-orm"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { getChatById } from "@in/server/modules/subthreads"

export const AccessGuards = {
  ensureChatAccess,
  ensureSpaceMember,
}

// TODO: this can all be optimized to use less queries and be smarter about caching with a simpler API.

async function ensureChatAccess(chat: DbChat, userId: number) {
  if (chat.type === "private") {
    if (chat.minUserId !== userId && chat.maxUserId !== userId) {
      throw RealtimeRpcError.PeerIdInvalid()
    }
    return
  }

  if (await hasDirectChatParticipant(chat.id, userId)) {
    return
  }

  if (chat.parentChatId != null) {
    const parentChat = await getChatById(chat.parentChatId)
    if (!parentChat) {
      throw RealtimeRpcError.PeerIdInvalid()
    }

    await ensureInheritedChatAccess(parentChat, userId)
    return
  }

  await ensureTopLevelChatAccess(chat, userId)
}

async function ensureInheritedChatAccess(chat: DbChat, userId: number) {
  if (chat.parentChatId != null) {
    const parentChat = await getChatById(chat.parentChatId)
    if (!parentChat) {
      throw RealtimeRpcError.PeerIdInvalid()
    }

    await ensureInheritedChatAccess(parentChat, userId)
    return
  }

  await ensureTopLevelChatAccess(chat, userId)
}

async function ensureTopLevelChatAccess(chat: DbChat, userId: number) {
  if (chat.type === "private") {
    if (chat.minUserId !== userId && chat.maxUserId !== userId) {
      throw RealtimeRpcError.PeerIdInvalid()
    }
    return
  }

  if (!chat.spaceId) {
    await ensureChatParticipant(chat.id, userId)
    return
  }

  await ensureSpaceMember(chat.spaceId, userId)

  if (chat.publicThread) {
    const member = await MembersModel.getMemberByUserId(chat.spaceId, userId)
    if (!member || member.canAccessPublicChats === false) {
      throw RealtimeRpcError.PeerIdInvalid()
    }
    return
  }

  await ensureChatParticipant(chat.id, userId)
}

async function ensureSpaceMember(spaceId: number, userId: number) {
  const cachedMember = AccessGuardsCache.getSpaceMember(spaceId, userId)
  if (cachedMember !== undefined) {
    if (!cachedMember) {
      throw RealtimeRpcError.SpaceIdInvalid()
    }
    return
  }

  const isMember = await MembersModel.isUserMemberOfSpace(spaceId, userId)
  if (isMember) {
    AccessGuardsCache.setSpaceMember(spaceId, userId)
  }

  if (!isMember) {
    throw RealtimeRpcError.SpaceIdInvalid()
  }
}

async function ensureChatParticipant(chatId: number, userId: number) {
  const exists = await hasDirectChatParticipant(chatId, userId)
  if (!exists) {
    throw RealtimeRpcError.PeerIdInvalid()
  }
}

async function hasDirectChatParticipant(chatId: number, userId: number): Promise<boolean> {
  const cachedParticipant = AccessGuardsCache.getChatParticipant(chatId, userId)
  if (cachedParticipant !== undefined) {
    return cachedParticipant
  }

  const participant = await db
    .select({ id: chatParticipants.id })
    .from(chatParticipants)
    .where(and(eq(chatParticipants.chatId, chatId), eq(chatParticipants.userId, userId)))
    .limit(1)

  const exists = participant.length > 0
  if (exists) {
    AccessGuardsCache.setChatParticipant(chatId, userId)
  }

  return exists
}
