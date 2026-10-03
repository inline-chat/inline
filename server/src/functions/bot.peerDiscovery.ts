import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { ChatModel } from "@in/server/db/models/chats"
import { UsersModel } from "@in/server/db/models/users"
import { chatParticipants, members, userNotDeleted, users, type DbChat } from "@in/server/db/schema"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getChatById } from "@in/server/modules/subthreads"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { InputPeer } from "@inline-chat/protocol/core"
import { and, asc, eq } from "drizzle-orm"

async function getParticipantBotUserIds(chatId: number, options?: { tx?: Transaction }): Promise<number[]> {
  const rows = await (options?.tx ?? db)
    .select({ userId: chatParticipants.userId })
    .from(chatParticipants)
    .innerJoin(users, eq(chatParticipants.userId, users.id))
    .where(and(eq(chatParticipants.chatId, chatId), eq(users.bot, true), userNotDeleted()))
    .orderBy(asc(chatParticipants.userId))
  return rows.map((row) => row.userId)
}

export async function getPublicSpaceBotUserIds(spaceId: number, options?: { tx?: Transaction }): Promise<number[]> {
  const rows = await (options?.tx ?? db)
    .select({ userId: members.userId })
    .from(members)
    .innerJoin(users, eq(members.userId, users.id))
    .where(and(
      eq(members.spaceId, spaceId),
      eq(members.canAccessPublicChats, true),
      eq(users.bot, true),
      userNotDeleted(),
    ))
    .orderBy(asc(members.userId))
  return rows.map((row) => row.userId)
}

async function getPrivatePeerBotUserId(chat: DbChat, currentUserId: number, options?: { tx?: Transaction }): Promise<number[]> {
  const peerUserId = chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId
  if (!peerUserId) return []
  const peer = (await UsersModel.getUsersWithPhotos([peerUserId], options))[0]?.user
  return peer?.bot === true && peer.deleted !== true ? [peerUserId] : []
}

async function getTopLevelBotUserIds(chat: DbChat, currentUserId: number, options?: { tx?: Transaction }): Promise<number[]> {
  if (chat.type === "private") {
    return [
      ...(await getParticipantBotUserIds(chat.id, options)),
      ...(await getPrivatePeerBotUserId(chat, currentUserId, options)),
    ]
  }
  if (chat.spaceId && chat.publicThread) {
    return [
      ...(await getPublicSpaceBotUserIds(chat.spaceId, options)),
      ...(await getParticipantBotUserIds(chat.id, options)),
    ]
  }
  return getParticipantBotUserIds(chat.id, options)
}

export async function getBotUserIdsForChatScope(
  chat: DbChat,
  currentUserId: number,
  visitedChatIds = new Set<number>(),
  options?: { tx?: Transaction },
): Promise<number[]> {
  if (visitedChatIds.has(chat.id)) return []
  visitedChatIds.add(chat.id)
  if (chat.parentChatId == null) return getTopLevelBotUserIds(chat, currentUserId, options)

  const [directIds, parentChat] = await Promise.all([
    getParticipantBotUserIds(chat.id, options),
    getChatById(chat.parentChatId, options),
  ])
  if (!parentChat) return directIds
  return [...directIds, ...(await getBotUserIdsForChatScope(parentChat, currentUserId, visitedChatIds, options))]
}

export async function resolvePeerBotScope(
  peerId: InputPeer | undefined,
  currentUserId: number,
): Promise<{ chat: DbChat; botUserIds: number[] }> {
  if (!peerId?.type.oneofKind) throw RealtimeRpcError.BadRequest()
  const chat = await ChatModel.getChatFromInputPeer(peerId, { currentUserId })
  await AccessGuards.ensureChatAccess(chat, currentUserId)
  return {
    chat,
    botUserIds: Array.from(new Set(await getBotUserIdsForChatScope(chat, currentUserId))).sort((a, b) => a - b),
  }
}
