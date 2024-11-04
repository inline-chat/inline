import { db } from "@in/server/db"
import { chats } from "@in/server/db/schema"
import { encodeChatInfo, TChatInfo } from "@in/server/models"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { eq, sql } from "drizzle-orm"
import type { Static } from "elysia"
import { Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"

export const Input = Type.Object({
  title: Type.String(),
  spaceId: Type.String(),
})

export const Response = Type.Object({
  chat: TChatInfo,
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  try {
    const spaceId = parseInt(input.spaceId, 10)
    if (isNaN(spaceId)) {
      throw new InlineError(InlineError.ApiError.SPACE_INVALID)
    }
    var maxThreadNumber: number = await db
      // MAX function returns the maximum value in a set of values
      .select({ maxThreadNumber: sql<number>`MAX(${chats.threadNumber})` })
      .from(chats)
      .where(eq(chats.spaceId, spaceId))
      .then((result) => result[0]?.maxThreadNumber ?? 0)

    var threadNumber = maxThreadNumber + 1

    const chat = await db
      .insert(chats)
      .values({
        type: "thread",
        spaceId: spaceId,
        title: input.title,
        publicThread: true,
        date: new Date(),
        threadNumber: threadNumber,
      })
      .returning()

    if (!chat[0]) {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    return { chat: encodeChatInfo(chat[0], { currentUserId: context.currentUserId }) }
  } catch (error) {
    Log.shared.error("Failed to create thread", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
