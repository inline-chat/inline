import type { UpdateChatInfoInput, UpdateChatInfoResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Method } from "@in/protocol/core"

export const method = Method.UPDATE_CHAT_INFO

export const updateChatInfoHandler = async (
  input: UpdateChatInfoInput,
  handlerContext: HandlerContext,
): Promise<UpdateChatInfoResult> => {
  const { chat } = await Functions.messages.updateChatInfo(
    {
      chatId: Number(input.chatId),
      title: input.title,
      emoji: input.emoji,
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
