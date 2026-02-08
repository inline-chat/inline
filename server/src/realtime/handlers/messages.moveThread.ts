import type { MoveThreadInput, MoveThreadResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Method } from "@in/protocol/core"

export const method = Method.MOVE_THREAD

export const moveThreadHandler = async (
  input: MoveThreadInput,
  handlerContext: HandlerContext,
): Promise<MoveThreadResult> => {
  const { chat } = await Functions.messages.moveThread(
    {
      chatId: Number(input.chatId),
      spaceId: input.spaceId !== undefined ? Number(input.spaceId) : null,
    },
    {
      currentUserId: handlerContext.userId,
      currentSessionId: handlerContext.sessionId,
    },
  )

  return {
    chat: Encoders.chat(chat, { encodingForUserId: handlerContext.userId }),
  }
}

