import type { InputPeer, Update } from "@in/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { MessageModel } from "@in/server/db/models/messages"
import type { FunctionContext } from "@in/server/functions/_types"
import { Updates } from "@in/server/modules/updates/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { ReactionModel } from "../db/models/reactions"

type Input = {
  emoji: string
  messageId: bigint
  peer: InputPeer
}

type Output = {
  updates: Update[]
}

export const deleteReaction = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chatId = await ChatModel.getChatIdFromInputPeer(input.peer, context)

  const result = await ReactionModel.deleteReaction(input.messageId, chatId, input.emoji, context.currentUserId)
  console.log("deleteReaction result", result)

  console.log("input", input)
  const update: Update = {
    update: {
      oneofKind: "deleteReaction",
      deleteReaction: {
        emoji: input.emoji,
        chatId: BigInt(chatId),
        messageId: input.messageId,
      },
    },
  }

  Updates.shared.pushUpdate([update], { peerId: input.peer, currentUserId: context.currentUserId })

  return { updates: [update] }
}
