import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { userNotDeleted, users } from "@in/server/db/schema"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import {
  botPresenceStateTimeoutMs,
  expireBotPresenceState,
} from "@in/server/modules/botPresence/state"
import { getSharedBotPresence, setSharedBotPresence } from "@in/server/modules/botPresence/shared"
import { getUpdateGroupFromInputPeer, type UpdateGroup } from "@in/server/modules/updates"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import { publishBotPresence } from "@in/server/modules/internalMessaging/transient"
import type {
  BotPresenceState,
  InputPeer,
  SetBotPresenceStateInput,
  SetBotPresenceStateResult,
  Update,
} from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import type { FunctionContext } from "./_types"

const log = new Log("functions.setBotPresenceState")
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
  await requireBot(botUserId)

  const chat = await ChatModel.getChatFromInputPeer(peerIdInput, context)
  await AccessGuards.ensureChatAccess(chat, botUserId)

  const { state, activityId } = await setSharedBotPresence(botUserId, chat.id, inputState)
  const updateGroup = await getUpdateGroupFromInputPeer(peerIdInput, context)

  pushBotPresenceUpdate({
    botUserId,
    inputPeer: peerIdInput,
    state,
    updateGroup,
  })
  publishBotPresenceHints({
    recipientUserIds: updateGroup.userIds,
    botUserId,
    chatId: chat.id,
    activityId,
  })
  scheduleBotPresenceExpiry({
    botUserId,
    chatId: chat.id,
    inputPeer: peerIdInput,
    state,
    activityId,
    updateGroup,
  })

  return {}
}

/**
 * Presence hints are best-effort. The process-owned dispatcher bounds every
 * recipient publication and never adds broker latency to the RPC result.
 */
export function publishBotPresenceHints(input: {
  readonly recipientUserIds: readonly number[]
  readonly botUserId: number
  readonly chatId: number
  readonly activityId: string
}): void {
  for (const userId of input.recipientUserIds) {
    if (userId !== input.botUserId) {
      publishBotPresence(userId, input.botUserId, input.chatId, input.activityId)
    }
  }
}

function pushBotPresenceUpdate({
  botUserId,
  inputPeer,
  state,
  updateGroup,
}: {
  botUserId: number
  inputPeer: InputPeer
  state: BotPresenceState
  updateGroup: UpdateGroup
}) {
  for (const userId of updateGroup.userIds) {
    if (userId === botUserId) {
      continue
    }

    const peerId = updatePeer(inputPeer, userId, botUserId, updateGroup.type)
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
}

function scheduleBotPresenceExpiry({
  botUserId,
  chatId,
  inputPeer,
  state,
  activityId,
  updateGroup,
}: {
  botUserId: number
  chatId: number
  inputPeer: InputPeer
  state: BotPresenceState
  activityId: string
  updateGroup: UpdateGroup
}) {
  const timeoutMs = botPresenceStateTimeoutMs(state)
  if (timeoutMs == null) {
    return
  }

  const timer = setTimeout(() => {
    void expireAndPushBotPresence({
      botUserId,
      chatId,
      inputPeer,
      updateGroup,
      activityId,
    })
  }, timeoutMs + 50)

  timer.unref?.()
}

async function expireAndPushBotPresence({
  botUserId,
  chatId,
  inputPeer,
  updateGroup,
  activityId,
}: {
  botUserId: number
  chatId: number
  inputPeer: InputPeer
  updateGroup: UpdateGroup
  activityId: string
}) {
  try {
    const shared = await getSharedBotPresence(botUserId, chatId)
    if (shared.status === "available" && shared.activityId !== undefined) return
    const currentUpdateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId: botUserId }).catch(
      (error) => {
        log.warn("Failed to refresh bot presence expiry update group", { error, botUserId, chatId })
        return updateGroup
      },
    )
    const expiredState = expireBotPresenceState(botUserId, chatId, Date.now(), activityId)
    if (!expiredState) {
      return
    }

    pushBotPresenceUpdate({
      botUserId,
      inputPeer,
      state: expiredState,
      updateGroup: currentUpdateGroup,
    })
  } catch (error) {
    log.error("Failed to expire bot presence state", { error, botUserId, chatId })
  }
}

async function requireBot(botUserId: number) {
  const [row] = await db
    .select({ id: users.id })
    .from(users)
    .where(and(eq(users.id, botUserId), eq(users.bot, true), userNotDeleted()))
    .limit(1)

  if (!row) {
    throw RealtimeRpcError.UserIdInvalid()
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
