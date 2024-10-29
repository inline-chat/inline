import { db } from "@in/server/db"
import { desc, eq, sql } from "drizzle-orm"
import { chats, messages } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import { encodeMessageInfo, TMessageInfo } from "@in/server/models"

export const Input = Type.Object({
  chatId: Type.String(),
  text: Type.String(),
  peerUserIds: Type.Array(Type.String()),
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
    const chatId = parseInt(input.chatId, 10)
    if (isNaN(chatId)) {
      throw new InlineError(ErrorCodes.INVALID_INPUT, "Invalid chat ID")
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
      })
      .returning()

    await db
      .update(chats)
      .set({ maxMsgId: prevMessageId + 1 })
      .where(eq(chats.id, chatId))

    return { message: encodeMessageInfo(newMessage) }
  } catch (error) {
    Log.shared.error("Failed to get chat history", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to get chat history")
  }
}
