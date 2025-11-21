import type { DbChat } from "@in/server/db/schema"
import { MembersModel } from "@in/server/db/models/members"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { db } from "@in/server/db"
import { chatParticipants } from "@in/server/db/schema/chats"
import { and, eq } from "drizzle-orm"

export const AccessGuards = {
  ensureChatAccess,
  ensureSpaceMember,
}

async function ensureChatAccess(chat: DbChat, userId: number) {
  if (chat.type === "private") {
    if (chat.minUserId !== userId && chat.maxUserId !== userId) {
      throw RealtimeRpcError.PeerIdInvalid
    }
    return
  }

  if (!chat.spaceId) {
    throw RealtimeRpcError.ChatIdInvalid
  }

  await ensureSpaceMember(chat.spaceId, userId)

  if (!chat.publicThread) {
    const participant = await db
      .select({ id: chatParticipants.id })
      .from(chatParticipants)
      .where(and(eq(chatParticipants.chatId, chat.id), eq(chatParticipants.userId, userId)))
      .limit(1)

    if (participant.length === 0) {
      throw RealtimeRpcError.PeerIdInvalid
    }
  }
}

async function ensureSpaceMember(spaceId: number, userId: number) {
  const isMember = await MembersModel.isUserMemberOfSpace(spaceId, userId)
  if (!isMember) {
    throw RealtimeRpcError.SpaceIdInvalid
  }
}

