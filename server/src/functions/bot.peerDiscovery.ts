import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { UsersModel } from "@in/server/db/models/users"
import { chatParticipants, members, userNotDeleted, users, type DbChat } from "@in/server/db/schema"
import { resolveBotReachForBots } from "@in/server/modules/agents/access"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getChatById } from "@in/server/modules/subthreads"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { InputPeer } from "@inline-chat/protocol/core"
import { and, asc, eq } from "drizzle-orm"

async function getParticipantBotUserIds(chatId: number): Promise<number[]> {
  const rows = await db
    .select({ userId: chatParticipants.userId })
    .from(chatParticipants)
    .innerJoin(users, eq(chatParticipants.userId, users.id))
    .where(and(eq(chatParticipants.chatId, chatId), eq(users.bot, true), userNotDeleted()))
    .orderBy(asc(chatParticipants.userId))
  return rows.map((row) => row.userId)
}

export async function getPublicSpaceBotUserIds(spaceId: number): Promise<number[]> {
  const rows = await db
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

async function getPrivatePeerBotUserId(chat: DbChat, currentUserId: number): Promise<number[]> {
  const peerUserId = chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId
  if (!peerUserId) return []
  const peer = (await UsersModel.getUsersWithPhotos([peerUserId]))[0]?.user
  return peer?.bot === true && peer.deleted !== true ? [peerUserId] : []
}

async function getTopLevelBotUserIds(chat: DbChat, currentUserId: number): Promise<number[]> {
  // Ordered nearest-first: the DM's own bot, then bots in this chat, then space-wide bots.
  if (chat.type === "private") {
    return [
      ...(await getPrivatePeerBotUserId(chat, currentUserId)),
      ...(await getParticipantBotUserIds(chat.id)),
    ]
  }
  if (chat.spaceId && chat.publicThread) {
    return [
      ...(await getParticipantBotUserIds(chat.id)),
      ...(await getPublicSpaceBotUserIds(chat.spaceId)),
    ]
  }
  return getParticipantBotUserIds(chat.id)
}

export async function getBotUserIdsForChatScope(
  chat: DbChat,
  currentUserId: number,
  visitedChatIds = new Set<number>(),
): Promise<number[]> {
  if (visitedChatIds.has(chat.id)) return []
  visitedChatIds.add(chat.id)
  if (chat.parentChatId == null) return getTopLevelBotUserIds(chat, currentUserId)

  const [directIds, parentChat] = await Promise.all([
    getParticipantBotUserIds(chat.id),
    getChatById(chat.parentChatId),
  ])
  if (!parentChat) return directIds
  return [...directIds, ...(await getBotUserIdsForChatScope(parentChat, currentUserId, visitedChatIds))]
}

/** The chat's bots the caller can reach: what discovery lists and what a typed command may target. */
export async function getReachableBotUserIdsForChatScope(chat: DbChat, currentUserId: number): Promise<number[]> {
  const botUserIds = Array.from(new Set(await getBotUserIdsForChatScope(chat, currentUserId)))
  if (botUserIds.length === 0) return []
  const reachable = new Set(
    (await resolveBotReachForBots(botUserIds, currentUserId))
      .filter(({ reach }) => reach.canMessage)
      .map(({ bot }) => bot.id),
  )
  return botUserIds.filter((botUserId) => reachable.has(botUserId))
}

export async function resolvePeerBotScope(
  peerId: InputPeer | undefined,
  currentUserId: number,
): Promise<{ chat: DbChat; botUserIds: number[]; botUserIdsByProximity: number[] }> {
  if (!peerId?.type.oneofKind) throw RealtimeRpcError.BadRequest()
  const chat = await ChatModel.getChatFromInputPeerUnchecked(peerId, { currentUserId })
  await AccessGuards.ensureChatAccess(chat, currentUserId)
  // Each bot stays at its first (nearest) scope position. Bots the caller
  // can't reach are left out, so their commands and Agents aren't offered.
  const botUserIdsByProximity = await getReachableBotUserIdsForChatScope(chat, currentUserId)
  return {
    chat,
    botUserIds: [...botUserIdsByProximity].sort((a, b) => a - b),
    botUserIdsByProximity,
  }
}

/** A mentioned agent can be configured before sending the message that adds it
 * to the chat. Only its owner gets this pre-join path; chat access is still
 * checked, and ordinary discovery continues to list the chat's actual bots. */
export async function resolvePeerBotConfigurationScope(
  peerId: InputPeer | undefined,
  botUserId: number,
  currentUserId: number,
): Promise<{ chat: DbChat }> {
  const { chat, botUserIds } = await resolvePeerBotScope(peerId, currentUserId)
  if (!botUserIds.includes(botUserId)) {
    const bot = await UsersModel.getUserById(botUserId)
    if (bot?.bot !== true || bot.deleted === true || bot.botCreatorId !== currentUserId) {
      throw RealtimeRpcError.UserIdInvalid()
    }
  }
  return { chat }
}
