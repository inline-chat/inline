import type { DbChat } from "@in/server/db/schema"
import { MembersModel } from "@in/server/db/models/members"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { db } from "@in/server/db"
import { chatParticipants } from "@in/server/db/schema/chats"
import { and, eq } from "drizzle-orm"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"

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

  if (!chat.spaceId) {
    throw RealtimeRpcError.ChatIdInvalid()
  }

  await ensureSpaceMember(chat.spaceId, userId)

  // Public threads are only accessible to members with public access enabled.
  if (chat.publicThread) {
    const member = await MembersModel.getMemberByUserId(chat.spaceId, userId)
    if (!member || member.canAccessPublicChats === false) {
      throw RealtimeRpcError.PeerIdInvalid()
    }
    return
  }

  if (!chat.publicThread) {
    const cachedParticipant = AccessGuardsCache.getChatParticipant(chat.id, userId)
    if (cachedParticipant !== undefined) {
      if (!cachedParticipant) {
        throw RealtimeRpcError.PeerIdInvalid()
      }
      return
    }

    const participant = await db
      .select({ id: chatParticipants.id })
      .from(chatParticipants)
      .where(and(eq(chatParticipants.chatId, chat.id), eq(chatParticipants.userId, userId)))
      .limit(1)

    const exists = participant.length > 0
    if (exists) {
      AccessGuardsCache.setChatParticipant(chat.id, userId)
    }

    if (!exists) {
      throw RealtimeRpcError.PeerIdInvalid()
    }
  }
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
