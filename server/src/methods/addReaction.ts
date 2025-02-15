import type { HandlerContext } from "@in/server/controllers/helpers"
import { db } from "@in/server/db"
import { Log } from "@in/server/utils/log"
import { Type } from "@sinclair/typebox"
import type { Static } from "elysia"
import { encodeReactionInfo, TReactionInfo } from "../api-types"
import { reactions } from "../db/schema/reactions"
import { InlineError } from "../types/errors"
import { TInputId } from "../types/methods"

export const Input = Type.Object({
  messageId: TInputId,
  chatId: TInputId,
  emoji: Type.String(),
})

export const Response = Type.Object({
  reaction: TReactionInfo,
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  try {
    const chatId = Number(input.chatId)
    if (isNaN(chatId)) {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }
    const messageId = Number(input.messageId)
    if (isNaN(messageId)) {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }

    const [reaction] = await db
      .insert(reactions)
      .values({
        messageId: messageId,
        chatId: chatId,
        emoji: input.emoji,
        userId: context.currentUserId,
        date: new Date(),
      })
      .returning()

    if (!reaction) {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    return {
      reaction: encodeReactionInfo(reaction),
    }
  } catch (error) {
    Log.shared.error("Failed to add reaction", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
