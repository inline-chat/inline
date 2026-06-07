import { BotCommandsModel } from "@in/server/db/models/botCommands"
import { ChatModel } from "@in/server/db/models/chats"
import { UsersModel } from "@in/server/db/models/users"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { db } from "@in/server/db"
import { chatParticipants, members, userNotDeleted, users, type DbChat } from "@in/server/db/schema"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { and, asc, eq } from "drizzle-orm"
import type { FunctionContext } from "@in/server/functions/_types"
import type { GetPeerBotCommandsInput, GetPeerBotCommandsResult } from "@inline-chat/protocol/core"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { toProtocolBotCommand } from "./bot.commandsShared"
import { getChatById } from "@in/server/modules/subthreads"

async function getRelevantBotUserIdsForChat(chatId: number): Promise<number[]> {
  const rows = await db
    .select({ userId: chatParticipants.userId })
    .from(chatParticipants)
    .innerJoin(users, eq(chatParticipants.userId, users.id))
    .where(and(eq(chatParticipants.chatId, chatId), eq(users.bot, true), userNotDeleted()))
    .orderBy(asc(chatParticipants.userId))

  return rows.map((row) => row.userId)
}

async function getRelevantBotUserIdsForPublicSpace(spaceId: number): Promise<number[]> {
  const rows = await db
    .select({ userId: members.userId })
    .from(members)
    .innerJoin(users, eq(members.userId, users.id))
    .where(
      and(
        eq(members.spaceId, spaceId),
        eq(members.canAccessPublicChats, true),
        eq(users.bot, true),
        userNotDeleted(),
      ),
    )
    .orderBy(asc(members.userId))

  return rows.map((row) => row.userId)
}

async function getBotUserIdsForPrivatePeer(chat: DbChat, currentUserId: number): Promise<number[]> {
  const peerUserId = chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId
  if (!peerUserId) {
    return []
  }

  const peerRows = await UsersModel.getUsersWithPhotos([peerUserId])
  const peerUser = peerRows[0]?.user
  if (peerUser?.bot !== true || peerUser.deleted === true) {
    return []
  }

  return [peerUserId]
}

async function getTopLevelBotUserIds(chat: DbChat, currentUserId: number): Promise<number[]> {
  if (chat.type === "private") {
    return [
      ...(await getRelevantBotUserIdsForChat(chat.id)),
      ...(await getBotUserIdsForPrivatePeer(chat, currentUserId)),
    ]
  }

  if (chat.spaceId && chat.publicThread) {
    return [
      ...(await getRelevantBotUserIdsForPublicSpace(chat.spaceId)),
      ...(await getRelevantBotUserIdsForChat(chat.id)),
    ]
  }

  return getRelevantBotUserIdsForChat(chat.id)
}

async function getBotUserIdsForChatScope(
  chat: DbChat,
  currentUserId: number,
  visitedChatIds = new Set<number>(),
): Promise<number[]> {
  if (visitedChatIds.has(chat.id)) {
    return []
  }
  visitedChatIds.add(chat.id)

  if (chat.parentChatId == null) {
    return getTopLevelBotUserIds(chat, currentUserId)
  }

  const [directBotUserIds, parentChat] = await Promise.all([
    getRelevantBotUserIdsForChat(chat.id),
    getChatById(chat.parentChatId),
  ])

  if (!parentChat) {
    return directBotUserIds
  }

  return [
    ...directBotUserIds,
    ...(await getBotUserIdsForChatScope(parentChat, currentUserId, visitedChatIds)),
  ]
}

export const getPeerBotCommands = async (
  input: GetPeerBotCommandsInput,
  context: FunctionContext,
): Promise<GetPeerBotCommandsResult> => {
  if (!input.peerId?.type.oneofKind) {
    throw RealtimeRpcError.BadRequest()
  }

  const chat = await ChatModel.getChatFromInputPeer(input.peerId, { currentUserId: context.currentUserId })
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)

  const uniqueBotUserIds = Array.from(new Set(await getBotUserIdsForChatScope(chat, context.currentUserId)))
  if (uniqueBotUserIds.length === 0) {
    return { bots: [] }
  }

  const botRows = await UsersModel.getUsersWithPhotos(uniqueBotUserIds)
  const commandsByBotUserId = await BotCommandsModel.getForBotUserIds(uniqueBotUserIds)

  return {
    bots: botRows
      .filter((row) => (commandsByBotUserId.get(row.user.id)?.length ?? 0) > 0)
      .map((row) => ({
        bot: Encoders.user({
          user: row.user,
          photoFile: row.photoFile,
          min: false,
        }),
        commands: (commandsByBotUserId.get(row.user.id) ?? []).map(toProtocolBotCommand),
      })),
  }
}
