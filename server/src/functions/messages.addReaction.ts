import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import type { FunctionContext } from "@in/server/functions/_types"
import { Updates } from "@in/server/modules/updates/updates"
import { ReactionModel } from "../db/models/reactions"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { BotUpdateProjector } from "@in/server/modules/botUpdates/projector"

type Input = {
  emoji: string
  messageId: bigint
  peer: InputPeer
}

type Output = {
  updates: Update[]
}

export const addReaction = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chat = await ChatModel.getChatFromInputPeer(input.peer, context)
  const chatId = chat.id

  const _reactions = await ReactionModel.insertReaction({
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

  BotUpdateProjector.reactionChanged({ chat, messageId: Number(input.messageId), actorUserId: context.currentUserId, emoji: input.emoji, added: true })

  return { updates: [update] }
}
