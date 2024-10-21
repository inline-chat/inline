import { db } from "@in/server/db"
import { chats, DbChat } from "@in/server/db/schema"
import { encodeChatInfo } from "@in/server/models"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { eq, sql } from "drizzle-orm"

type Input = {
  title: string
  spaceId: string
}

type Context = {
  currentUserId: number
}

type Output = {
  chat: DbChat
}

export const createThread = async (
  input: Input,
  context: Context,
): Promise<Output> => {
  try {
    const spaceId = parseInt(input.spaceId, 10)
    if (isNaN(spaceId)) {
      throw new InlineError(ErrorCodes.SERVER_ERROR, "Invalid spaceId")
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
        spaceId: spaceId,
        type: "thread",
        title: input.title,
        spacePublic: true,
        date: new Date(),
        threadNumber: threadNumber,
      })
      .returning()

    return { chat: chat[0] }
  } catch (error) {
    Log.shared.error("Failed to create thread", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to create thread")
  }
}

export const encodeCreateThread = (output: Output) => {
  return {
    chat: encodeChatInfo(output.chat),
  }
}
