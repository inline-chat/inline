import { BotCommandsModel } from "@in/server/db/models/botCommands"
import { ChatModel } from "@in/server/db/models/chats"
import { UsersModel } from "@in/server/db/models/users"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { db } from "@in/server/db"
import { chatParticipants, members, users } from "@in/server/db/schema"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { and, asc, eq, inArray, isNull, or } from "drizzle-orm"
import type { FunctionContext } from "@in/server/functions/_types"
import type { GetPeerBotCommandsInput, GetPeerBotCommandsResult } from "@inline-chat/protocol/core"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { toProtocolBotCommand } from "./bot.commandsShared"

async function getRelevantBotUserIdsForChat(chatId: number): Promise<number[]> {
  const rows = await db
    .select({ userId: chatParticipants.userId })
    .from(chatParticipants)
    .innerJoin(users, eq(chatParticipants.userId, users.id))
    .where(and(eq(chatParticipants.chatId, chatId), eq(users.bot, true), or(isNull(users.deleted), eq(users.deleted, false))))
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
        or(isNull(users.deleted), eq(users.deleted, false)),
      ),
    )
    .orderBy(asc(members.userId))

  return rows.map((row) => row.userId)
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

  let botUserIds: number[] = []

  if (chat.type === "private") {
    const peerUserId = chat.minUserId === context.currentUserId ? chat.maxUserId : chat.minUserId
    if (peerUserId) {
      const peerRows = await UsersModel.getUsersWithPhotos([peerUserId])
      const peerUser = peerRows[0]?.user
      if (peerUser?.bot === true && peerUser.deleted !== true) {
        botUserIds = [peerUserId]
      }
    }
  } else if (chat.spaceId && chat.publicThread) {
    botUserIds = await getRelevantBotUserIdsForPublicSpace(chat.spaceId)
  } else {
    botUserIds = await getRelevantBotUserIdsForChat(chat.id)
  }

  const uniqueBotUserIds = Array.from(new Set(botUserIds))
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
