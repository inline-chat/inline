import type { InputPeer, Message } from "@in/protocol/core"
import { ModelError } from "@in/server/db/models/_errors"
import { MessageModel, type DbFullMessage } from "@in/server/db/models/messages"
import { ChatModel } from "@in/server/db/models/chats"
import { UsersModel } from "@in/server/db/models/users"
import type { FunctionContext } from "@in/server/functions/_types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Log } from "@in/server/utils/log"
import { RealtimeRpcError } from "@in/server/realtime/errors"

type Input = {
  peerId: InputPeer
  offsetId?: bigint
  limit?: number
}

type Output = {
  messages: Message[]
}

const log = new Log("functions.getChatHistory")

async function getMessagesWithChatCreation(
  inputPeer: InputPeer,
  options: { currentUserId: number; offsetId?: bigint; limit?: number },
): Promise<DbFullMessage[]> {
  try {
    return await MessageModel.getMessages(inputPeer, options)
  } catch (error) {
    if (error instanceof ModelError && error.code === ModelError.Codes.CHAT_INVALID) {
      if (inputPeer.type.oneofKind === "user") {
        const peerUserId = Number(inputPeer.type.user.userId)

        if (!peerUserId || peerUserId <= 0) {
          throw RealtimeRpcError.UserIdInvalid
        }

        const user = await UsersModel.getUserById(peerUserId)
        if (!user) {
          throw RealtimeRpcError.UserIdInvalid
        }

        log.info("Auto-creating private chat and dialogs", {
          currentUserId: options.currentUserId,
          peerUserId,
        })

        await ChatModel.createUserChatAndDialog({
          peerUserId,
          currentUserId: options.currentUserId,
        })

        await ChatModel.createUserChatAndDialog({
          peerUserId: options.currentUserId,
          currentUserId: peerUserId,
        })

        return []
      }
    }

    throw error
  }
}

export const getChatHistory = async (input: Input, context: FunctionContext): Promise<Output> => {
  // input data
  const inputPeer = input.peerId

  // get messages
  const messages = await getMessagesWithChatCreation(inputPeer, {
    offsetId: input.offsetId,
    limit: input.limit,
    currentUserId: context.currentUserId,
  })

  // encode messages
  const encodedMessages = messages.map((message) =>
    Encoders.fullMessage({
      message,
      encodingForUserId: context.currentUserId,
      encodingForPeer: { inputPeer },
    }),
  )

  return {
    messages: encodedMessages,
  }
}
