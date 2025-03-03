import type { InputPeer, Message } from "@in/protocol/core"
import { ModelError } from "@in/server/db/models/_errors"
import { MessageModel } from "@in/server/db/models/messages"
import type { FunctionContext } from "@in/server/functions/_types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Log } from "@in/server/utils/log"

type Input = {
  peerId: InputPeer
  offsetId?: bigint
  limit?: number
}

type Output = {
  messages: Message[]
}

const log = new Log("functions.getChatHistory")

export const getChatHistory = async (input: Input, context: FunctionContext): Promise<Output> => {
  // input data
  const inputPeer = input.peerId

  // get messages
  const messages = await MessageModel.getMessages(inputPeer, {
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
