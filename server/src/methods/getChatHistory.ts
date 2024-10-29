import { db } from "@in/server/db"
import { desc, eq } from "drizzle-orm"
import { messages } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import { encodeMessageInfo, TMessageInfo } from "@in/server/models"

export const Input = Type.Object({
  id: Type.String(),
  limit: Type.Optional(Type.Integer({ default: 50 })),
})

type Input = Static<typeof Input>

type Context = {
  currentUserId: number
}

export const Response = Type.Object({
  messages: Type.Array(TMessageInfo),
})

type Response = Static<typeof Response>

export const handler = async (input: Input, context: Context): Promise<Response> => {
  try {
    const chatId = parseInt(input.id, 10)
    if (isNaN(chatId)) {
      throw new InlineError(ErrorCodes.INVALID_INPUT, "Invalid chat ID")
    }
    const result = await db
      .select()
      .from(messages)
      .where(eq(messages.chatId, chatId))
      .orderBy(desc(messages.date))
      .limit(input.limit ?? 50)

    return { messages: result.map(encodeMessageInfo) }
  } catch (error) {
    Log.shared.error("Failed to get chat history", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to get chat history")
  }
}
