import { db } from "@in/server/db"
import { chats, DbChat } from "@in/server/db/schema"
import { encodeChatInfo } from "@in/server/models"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"

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
    const chat = await db
      .insert(chats)
      .values({
        spaceId: parseInt(input.spaceId, 10),
        type: "thread",
        title: input.title,
        spacePublic: true,
        date: new Date(),
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
