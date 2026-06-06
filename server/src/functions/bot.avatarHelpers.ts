import { db } from "@in/server/db"
import { botAvatarAssets, chatParticipants, chats, files, userNotDeleted, users } from "@in/server/db/schema"
import { getBotPresenceState } from "@in/server/modules/botPresence/state"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import type { BotAvatar, Peer, Update, User } from "@inline-chat/protocol/core"
import { and, eq, inArray, or } from "drizzle-orm"
import type { FunctionContext } from "./_types"

export function parseBotUserId(value: bigint): number {
  const botUserId = Number(value)
  if (!Number.isFinite(botUserId) || botUserId <= 0) {
    throw RealtimeRpcError.BadRequest()
  }
  return botUserId
}

export async function requireManageableBot(botUserId: number, context: FunctionContext) {
  const [bot] = await db
    .select()
    .from(users)
    .where(and(eq(users.id, botUserId), eq(users.bot, true), userNotDeleted()))
    .limit(1)

  const canUpdateAsCreator = bot?.botCreatorId === context.currentUserId
  const canUpdateAsBotSelf = bot?.id === context.currentUserId

  if (!bot || (!canUpdateAsCreator && !canUpdateAsBotSelf)) {
    throw RealtimeRpcError.UserIdInvalid()
  }

  return bot
}

export async function encodeBotWithAvatar(botUserId: number): Promise<User> {
  const [row] = await db
    .select({ bot: users, photo: files })
    .from(users)
    .leftJoin(files, eq(users.photoFileId, files.id))
    .where(eq(users.id, botUserId))
    .limit(1)

  if (!row) {
    throw RealtimeRpcError.InternalError()
  }

  const [avatarRow] = await db
    .select({ avatar: botAvatarAssets, file: files })
    .from(botAvatarAssets)
    .innerJoin(files, eq(botAvatarAssets.fileId, files.id))
    .where(eq(botAvatarAssets.botUserId, botUserId))
    .limit(1)

  return Encoders.user({
    user: row.bot,
    photoFile: row.photo ?? undefined,
    botAvatar: avatarRow?.avatar,
    botAvatarFile: avatarRow?.file,
    min: false,
  })
}

export async function encodeCurrentBotAvatar(botUserId: number): Promise<BotAvatar | undefined> {
  const [avatarRow] = await db
    .select({ avatar: botAvatarAssets, file: files })
    .from(botAvatarAssets)
    .innerJoin(files, eq(botAvatarAssets.fileId, files.id))
    .where(eq(botAvatarAssets.botUserId, botUserId))
    .limit(1)

  if (!avatarRow) {
    return undefined
  }

  return Encoders.botAvatar({ avatar: avatarRow.avatar, file: avatarRow.file })
}

export async function notifyBotAvatarChanged(botUserId: number) {
  const avatar = await encodeCurrentBotAvatar(botUserId)
  await Promise.all([
    notifyDirectChats(botUserId, avatar),
    notifyThreadChats(botUserId, avatar),
  ])
}

async function notifyDirectChats(botUserId: number, avatar: BotAvatar | undefined) {
  const directChats = await db
    .select({ id: chats.id, minUserId: chats.minUserId, maxUserId: chats.maxUserId })
    .from(chats)
    .where(and(
      eq(chats.type, "private"),
      or(eq(chats.minUserId, botUserId), eq(chats.maxUserId, botUserId)),
    ))

  for (const chat of directChats) {
    const targetUserId = chat.minUserId === botUserId ? chat.maxUserId : chat.minUserId
    if (!targetUserId || targetUserId === botUserId) {
      continue
    }

    const peerId = encodePeerFromInputPeer({
      inputPeer: { type: { oneofKind: "user", user: { userId: BigInt(botUserId) } } },
      currentUserId: targetUserId,
    })
    pushAvatarChangedUpdate({
      targetUserId,
      botUserId,
      chatId: chat.id,
      peerId,
      avatar,
    })
  }
}

async function notifyThreadChats(botUserId: number, avatar: BotAvatar | undefined) {
  const botChatRows = await db
    .select({ chatId: chatParticipants.chatId })
    .from(chatParticipants)
    .innerJoin(chats, eq(chatParticipants.chatId, chats.id))
    .where(and(eq(chatParticipants.userId, botUserId), eq(chats.type, "thread")))

  const chatIds = botChatRows.map((row) => row.chatId)
  if (chatIds.length === 0) {
    return
  }

  const participantRows = await db
    .select({ chatId: chatParticipants.chatId, userId: chatParticipants.userId })
    .from(chatParticipants)
    .where(inArray(chatParticipants.chatId, chatIds))

  for (const participant of participantRows) {
    if (participant.userId === botUserId) {
      continue
    }

    const peerId = encodePeerFromInputPeer({
      inputPeer: { type: { oneofKind: "chat", chat: { chatId: BigInt(participant.chatId) } } },
      currentUserId: participant.userId,
    })
    pushAvatarChangedUpdate({
      targetUserId: participant.userId,
      botUserId,
      chatId: participant.chatId,
      peerId,
      avatar,
    })
  }
}

function pushAvatarChangedUpdate({
  targetUserId,
  botUserId,
  chatId,
  peerId,
  avatar,
}: {
  targetUserId: number
  botUserId: number
  chatId: number
  peerId: Peer
  avatar: BotAvatar | undefined
}) {
  const update: Update = {
    update: {
      oneofKind: "botPresence",
      botPresence: {
        botUserId: BigInt(botUserId),
        peerId,
        state: getBotPresenceState(botUserId, chatId),
        ...(avatar ? { avatar } : {}),
        avatarChanged: true,
      },
    },
  }

  RealtimeUpdates.pushToUser(targetUserId, [update])
}
