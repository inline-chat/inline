import type { UpdateChatVisibilityInput, UpdateChatVisibilityResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Method } from "@in/protocol/core"

export const method = Method.UPDATE_CHAT_VISIBILITY

export const updateChatVisibilityHandler = async (
  input: UpdateChatVisibilityInput,
  handlerContext: HandlerContext,
): Promise<UpdateChatVisibilityResult> => {
  const { chat } = await Functions.messages.updateChatVisibility(
    {
      chatId: Number(input.chatId),
      isPublic: Boolean(input.isPublic),
      participants: input.participants?.map((p) => Number(p.userId)),
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
