import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { MessageModel } from "@in/server/db/models/messages"
import { UsersModel } from "@in/server/db/models/users"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { findCallbackActionById } from "@in/server/modules/message/messageActions"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"

type Input = {
  peerId: InputPeer
  messageId: bigint
  actionId: string
}

type Output = {
  interactionId: bigint
}

export const invokeMessageAction = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)

  const messageId = Number(input.messageId)
  if (!Number.isSafeInteger(messageId) || messageId <= 0) {
    throw RealtimeRpcError.MessageIdInvalid()
  }

  const message = await MessageModel.getMessage(messageId, chat.id)

  const sender = await UsersModel.getUserById(message.fromId)
  if (!sender?.bot) {
    throw RealtimeRpcError.BadRequest()
  }

  const actionId = input.actionId.trim()
  const callback = findCallbackActionById({
    actions: message.actions,
    actionId,
  })

  if (!callback) {
    throw RealtimeRpcError.BadRequest()
  }

  const userUpdate = await UserBucketUpdates.enqueue({
    userId: sender.id,
    update: {
      oneofKind: "userMessageActionInvoked",
      userMessageActionInvoked: {
        chatId: BigInt(chat.id),
        messageId: BigInt(messageId),
        actorUserId: BigInt(context.currentUserId),
        actionId,
        data: callback.data,
      },
    },
  })

  const realtimeUpdate: Update = {
    seq: userUpdate.seq,
    date: encodeDateStrict(userUpdate.date),
    update: {
      oneofKind: "messageActionInvoked",
      messageActionInvoked: {
        interactionId: BigInt(userUpdate.seq),
        chatId: BigInt(chat.id),
        messageId: BigInt(messageId),
        actorUserId: BigInt(context.currentUserId),
        actionId,
        data: callback.data,
      },
    },
  }

  RealtimeUpdates.pushToUser(sender.id, [realtimeUpdate])

  return {
    interactionId: BigInt(userUpdate.seq),
  }
}
