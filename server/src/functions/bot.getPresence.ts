import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { botAvatarAssets, chatParticipants, files, userNotDeleted, users } from "@in/server/db/schema"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getBotPresenceState } from "@in/server/modules/botPresence/state"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { BotPresenceState_Kind, type GetBotPresenceInput, type GetBotPresenceResult } from "@inline-chat/protocol/core"
import { and, asc, eq } from "drizzle-orm"
import type { FunctionContext } from "./_types"

export const getBotPresence = async (
  input: GetBotPresenceInput,
  context: FunctionContext,
): Promise<GetBotPresenceResult> => {
  const peerIdInput = input.peerId
  if (!peerIdInput) {
    throw RealtimeRpcError.BadRequest()
  }

  const chat = await ChatModel.getChatFromInputPeer(peerIdInput, context)
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)

  const row =
    chat.type === "private"
      ? await getPrivateChatAvatar(chat.minUserId, chat.maxUserId, context.currentUserId)
      : await getThreadAvatar(chat.id)

  const peerId = encodePeerFromInputPeer({ inputPeer: peerIdInput, currentUserId: context.currentUserId })

  if (!row) {
    return {
      state: { kind: BotPresenceState_Kind.IDLE },
      peerId,
    }
  }

  return {
    botUserId: BigInt(row.avatar.botUserId),
    avatar: Encoders.botAvatar({ avatar: row.avatar, file: row.file }),
    state: getBotPresenceState(row.avatar.botUserId, chat.id),
    peerId,
  }
}

async function getPrivateChatAvatar(minUserId: number | null, maxUserId: number | null, currentUserId: number) {
  const botUserId = minUserId === currentUserId ? maxUserId : minUserId
  if (!botUserId) {
    return undefined
  }

  const [row] = await db
    .select({ avatar: botAvatarAssets, file: files })
    .from(botAvatarAssets)
    .innerJoin(users, eq(botAvatarAssets.botUserId, users.id))
    .innerJoin(files, eq(botAvatarAssets.fileId, files.id))
    .where(and(eq(botAvatarAssets.botUserId, botUserId), eq(users.bot, true), userNotDeleted()))
    .limit(1)

  return row
}

async function getThreadAvatar(chatId: number) {
  const [row] = await db
    .select({ avatar: botAvatarAssets, file: files })
    .from(chatParticipants)
    .innerJoin(users, eq(chatParticipants.userId, users.id))
    .innerJoin(botAvatarAssets, eq(users.id, botAvatarAssets.botUserId))
    .innerJoin(files, eq(botAvatarAssets.fileId, files.id))
    .where(and(eq(chatParticipants.chatId, chatId), eq(users.bot, true), userNotDeleted()))
    .orderBy(asc(users.id))
    .limit(1)

  return row
}
