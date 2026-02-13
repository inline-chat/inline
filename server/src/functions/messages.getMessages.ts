import type { InputPeer, Message } from "@inline-chat/protocol/core"
import { ModelError } from "@in/server/db/models/_errors"
import { ChatModel } from "@in/server/db/models/chats"
import { MessageModel, type DbFullMessage } from "@in/server/db/models/messages"
import { UsersModel } from "@in/server/db/models/users"
import type { DbChat } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"

type Input = {
  peerId: InputPeer
  messageIds: bigint[]
}

type Output = {
  messages: Message[]
}

const log = new Log("functions.getMessages")

export const getMessages = async (input: Input, context: FunctionContext): Promise<Output> => {
  validateMessageIds(input.messageIds)

  const chat = await getChatWithAccess(input.peerId, context.currentUserId)

  if (input.messageIds.length === 0) {
    return { messages: [] }
  }

  const uniqueIds = uniqueMessageIds(input.messageIds)
  const fullMessages = await MessageModel.getMessagesByIds(chat.id, uniqueIds)
  const orderedMessages = orderMessagesByRequestedIds(input.messageIds, fullMessages)

  return {
    messages: orderedMessages.map((message) =>
      Encoders.fullMessage({
        message,
        encodingForUserId: context.currentUserId,
        encodingForPeer: { inputPeer: input.peerId },
      }),
    ),
  }
}

async function getChatWithAccess(inputPeer: InputPeer, currentUserId: number): Promise<DbChat> {
  let chat: DbChat

  try {
    chat = await ChatModel.getChatFromInputPeer(inputPeer, { currentUserId })
  } catch (error) {
    if (error instanceof ModelError && error.code === ModelError.Codes.CHAT_INVALID) {
      if (inputPeer.type.oneofKind === "user") {
        const peerUserId = Number(inputPeer.type.user.userId)

        if (!peerUserId || peerUserId <= 0) {
          throw RealtimeRpcError.UserIdInvalid()
        }

        const user = await UsersModel.getUserById(peerUserId)
        if (!user) {
          throw RealtimeRpcError.UserIdInvalid()
        }

        log.info("Auto-creating private chat and dialogs", {
          currentUserId,
          peerUserId,
        })

        await ChatModel.createUserChatAndDialog({
          peerUserId,
          currentUserId,
        })

        await ChatModel.createUserChatAndDialog({
          peerUserId: currentUserId,
          currentUserId: peerUserId,
        })

        chat = await ChatModel.getChatFromInputPeer(inputPeer, { currentUserId })
      } else if (inputPeer.type.oneofKind === "chat") {
        throw RealtimeRpcError.ChatIdInvalid()
      } else {
        throw error
      }
    } else {
      throw error
    }
  }

  try {
    await AccessGuards.ensureChatAccess(chat, currentUserId)
  } catch (error) {
    log.error("getMessages blocked: chat access denied", {
      chatId: chat.id,
      currentUserId,
      inputPeer,
      error,
    })
    throw error
  }

  return chat
}

function validateMessageIds(messageIds: bigint[]): void {
  for (const messageId of messageIds) {
    if (messageId <= 0n) {
      throw RealtimeRpcError.MessageIdInvalid()
    }
  }
}

function uniqueMessageIds(messageIds: bigint[]): bigint[] {
  return Array.from(new Set(messageIds))
}

function orderMessagesByRequestedIds(requestedIds: bigint[], messages: DbFullMessage[]): DbFullMessage[] {
  const byMessageId = new Map<number, DbFullMessage>(messages.map((message) => [message.messageId, message]))
  const ordered: DbFullMessage[] = []

  for (const requestedId of requestedIds) {
    const message = byMessageId.get(Number(requestedId))
    if (message) {
      ordered.push(message)
    }
  }

  return ordered
}
