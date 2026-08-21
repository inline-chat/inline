import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import type { FunctionContext } from "@in/server/functions/_types"
import { Updates } from "@in/server/modules/updates/updates"
import { ReactionModel } from "../db/models/reactions"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { BotUpdateProjector } from "@in/server/modules/botUpdates/projector"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { isSingleEmoji } from "@in/server/utils/emoji"
import { RealtimeRpcError } from "@in/server/realtime/errors"

type Input = {
  emoji: string
  messageId: bigint
  peer: InputPeer
}

type Output = {
  updates: Update[]
}

export const addReaction = async (input: Input, context: FunctionContext): Promise<Output> => {
  const emoji = input.emoji.trim()
  if (!isSingleEmoji(emoji)) throw RealtimeRpcError.BadRequest()

  const chat = await ChatModel.getChatFromInputPeer(input.peer, context)
  const chatId = chat.id
  const updateGroup = await getUpdateGroupFromInputPeer(input.peer, { currentUserId: context.currentUserId })

  const reaction = await ReactionModel.insertReaction({
    messageId: Number(input.messageId),
    chatId: chatId,
    userId: context.currentUserId,
    emoji,
    date: new Date(),
  })

  if (!reaction) {
    return { updates: [] }
  }

  const update: Update = {
    update: {
      oneofKind: "updateReaction",
      updateReaction: {
        reaction: {
          emoji: reaction.emoji,
          messageId: BigInt(reaction.messageId),
          chatId: BigInt(reaction.chatId),
          userId: BigInt(reaction.userId),
          date: encodeDateStrict(reaction.date),
        },
      },
    },
  }

  await Updates.shared.pushUpdate([update], {
    peerId: input.peer,
    currentUserId: context.currentUserId,
    updateGroup,
  })

  BotUpdateProjector.reactionChanged({
    chat,
    messageId: Number(input.messageId),
    actorUserId: context.currentUserId,
    emoji,
    added: true,
  })

  return { updates: [update] }
}
