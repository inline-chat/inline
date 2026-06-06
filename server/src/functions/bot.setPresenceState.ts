import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { botAvatarAssets, chatParticipants, type DbChat, userNotDeleted, users } from "@in/server/db/schema"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { setBotPresenceState } from "@in/server/modules/botPresence/state"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import type { InputPeer, SetBotPresenceStateInput, SetBotPresenceStateResult, Update } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import type { FunctionContext } from "./_types"

export const setBotPresenceStateFn = async (
  input: SetBotPresenceStateInput,
  context: FunctionContext,
): Promise<SetBotPresenceStateResult> => {
  const peerIdInput = input.peerId
  const inputState = input.state
  if (!peerIdInput || !inputState) {
    throw RealtimeRpcError.BadRequest()
  }

  const botUserId = context.currentUserId
  await requireBotWithAvatar(botUserId)

  const chat = await ChatModel.getChatFromInputPeer(peerIdInput, context)
  await requireBotInChat(chat, botUserId)

  const state = setBotPresenceState(botUserId, chat.id, inputState)
  const updateGroup = await getUpdateGroupFromInputPeer(peerIdInput, context)

  for (const userId of updateGroup.userIds) {
    if (userId === botUserId) {
      continue
    }

    const peerId = updatePeer(peerIdInput, userId, botUserId, updateGroup.type)
    const update: Update = {
      update: {
        oneofKind: "botPresence",
          botPresence: {
            botUserId: BigInt(botUserId),
            peerId,
            state,
            avatarChanged: false,
          },
        },
      }

    RealtimeUpdates.pushToUser(userId, [update])
  }

  return {}
}

async function requireBotWithAvatar(botUserId: number) {
  const [row] = await db
    .select({ id: botAvatarAssets.id })
    .from(users)
    .innerJoin(botAvatarAssets, eq(users.id, botAvatarAssets.botUserId))
    .where(and(eq(users.id, botUserId), eq(users.bot, true), userNotDeleted()))
    .limit(1)

  if (!row) {
    throw RealtimeRpcError.UserIdInvalid()
  }
}

async function requireBotInChat(chat: DbChat, botUserId: number) {
  if (chat.type === "private") {
    if (chat.minUserId === botUserId || chat.maxUserId === botUserId) {
      return
    }
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const [participant] = await db
    .select({ id: chatParticipants.id })
    .from(chatParticipants)
    .where(and(eq(chatParticipants.chatId, chat.id), eq(chatParticipants.userId, botUserId)))
    .limit(1)

  if (!participant) {
    throw RealtimeRpcError.PeerIdInvalid()
  }
}

function updatePeer(
  inputPeer: InputPeer,
  userId: number,
  botUserId: number,
  updateGroupType: "dmUsers" | "threadUsers" | "spaceUsers",
) {
  if (updateGroupType === "dmUsers") {
    return encodePeerFromInputPeer({
      inputPeer: { type: { oneofKind: "user", user: { userId: BigInt(botUserId) } } },
      currentUserId: userId,
    })
  }

  return encodePeerFromInputPeer({ inputPeer, currentUserId: userId })
}
