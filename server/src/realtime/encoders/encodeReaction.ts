import type { DbReaction } from "@in/server/db/schema"
import type { Reaction } from "@in/protocol/core"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

export const encodeReaction = ({ reaction }: { reaction: DbReaction }): Reaction => {
  let reactionProto: Reaction = {
    emoji: reaction.emoji,
    userId: BigInt(reaction.userId),
    messageId: BigInt(reaction.messageId),
    chatId: BigInt(reaction.chatId),
    date: encodeDateStrict(reaction.date),
  }
  return reactionProto
}
