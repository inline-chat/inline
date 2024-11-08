import { db } from "@in/server/db"
import { desc, eq, sql } from "drizzle-orm"
import { chats, messages } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import { encodeMessageInfo, TMessageInfo } from "@in/server/models"

export const Input = Type.Object({
  // TODO: change to PeerId
  chatId: Type.String(),
  text: Type.String(),
})

type Input = Static<typeof Input>

type Context = {
  currentUserId: number
}

export const Response = Type.Object({
  message: TMessageInfo,
})

type Response = Static<typeof Response>

export const handler = async (input: Input, context: Context): Promise<Response> => {
  try {
    const chatId = Number(input.chatId)
    if (isNaN(chatId)) {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }

    var prevMessageId: number = await db
      .select({ messageId: sql<number>`MAX(${messages.messageId})` })
      .from(messages)
      .where(eq(messages.chatId, chatId))
      .then(([result]) => result?.messageId ?? 0)

    const [newMessage] = await db
      .insert(messages)
      .values({
        chatId: chatId,
        text: input.text,
        fromId: context.currentUserId,
        messageId: prevMessageId + 1,
        date: new Date(),
      })
      .returning()

    await db
      .update(chats)
      .set({ lastMsgId: prevMessageId + 1 })
      .where(eq(chats.id, chatId))

    if (!newMessage) {
      Log.shared.error("Failed to send message")
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    return { message: encodeMessageInfo(newMessage, { currentUserId: context.currentUserId }) }
  } catch (error) {
    Log.shared.error("Failed to send message", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
