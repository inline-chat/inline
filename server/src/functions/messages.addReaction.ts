import type { InputPeer, Update } from "@in/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { MessageModel } from "@in/server/db/models/messages"
import type { FunctionContext } from "@in/server/functions/_types"
import { Updates } from "@in/server/modules/updates/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { ReactionModel } from "../db/models/reactions"
import { encodeDate, encodeDateStrict } from "@in/server/realtime/encoders/helpers"

type Input = {
  emoji: string
  messageId: bigint
  peer: InputPeer
}

type Output = {
  updates: Update[]
}

export const addReaction = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chatId = await ChatModel.getChatIdFromInputPeer(input.peer, context)

  const reactions = await ReactionModel.insertReaction({
    messageId: Number(input.messageId),
    chatId: chatId,
    userId: context.currentUserId,
    emoji: input.emoji,
    date: new Date(),
  })

  const update: Update = {
    update: {
      oneofKind: "updateReaction",
      updateReaction: {
        reaction: {
          emoji: input.emoji,
          messageId: input.messageId,
          chatId: BigInt(chatId),
          userId: BigInt(context.currentUserId),
          date: encodeDateStrict(new Date()),
        },
      },
    },
  }

  Updates.shared.pushUpdate([update], { peerId: input.peer, currentUserId: context.currentUserId })

  return { updates: [update] }
}
