import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import type { FunctionContext } from "@in/server/functions/_types"
import { Updates } from "@in/server/modules/updates/updates"
import { ReactionModel } from "../db/models/reactions"
import { BotUpdateProjector } from "@in/server/modules/botUpdates/projector"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"

type Input = {
  emoji: string
  messageId: bigint
  peer: InputPeer
}

type Output = {
  updates: Update[]
}

export const deleteReaction = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chat = await ChatModel.getChatFromInputPeer(input.peer, context)
  const chatId = chat.id
  const updateGroup = await getUpdateGroupFromInputPeer(input.peer, { currentUserId: context.currentUserId })

  const result = await ReactionModel.deleteReactionWithUpdate(input.messageId, chatId, input.emoji, context.currentUserId)

  if (!result) {
    return { updates: [] }
  }

  const update: Update = {
    seq: result.update.seq,
    date: encodeDateStrict(result.update.date),
    update: {
      oneofKind: "deleteReaction",
      deleteReaction: {
        emoji: input.emoji,
        chatId: BigInt(chatId),
        messageId: input.messageId,
        userId: BigInt(context.currentUserId),
      },
    },
  }

  await Updates.shared.pushUpdate([update], {
    peerId: input.peer,
    currentUserId: context.currentUserId,
    updateGroup,
  })

  BotUpdateProjector.reactionChanged({ chat, messageId: Number(input.messageId), actorUserId: context.currentUserId, emoji: input.emoji, added: false })

  return { updates: [update] }
}
