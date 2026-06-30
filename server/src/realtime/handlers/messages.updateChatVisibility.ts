import type { UpdateChatVisibilityInput, UpdateChatVisibilityResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Method } from "@inline-chat/protocol/core"
import { RealtimeRpcError } from "@in/server/realtime/errors"

export const method = Method.UPDATE_CHAT_VISIBILITY

export const updateChatVisibilityHandler = async (
  input: UpdateChatVisibilityInput,
  handlerContext: HandlerContext,
): Promise<UpdateChatVisibilityResult> => {
  const participants = input.participants?.map((participant) => {
    if (participant.groupId != null || participant.userId == null) {
      throw RealtimeRpcError.BadRequest()
    }

    return Number(participant.userId)
  })

  const { chat } = await Functions.messages.updateChatVisibility(
    {
      chatId: Number(input.chatId),
      isPublic: Boolean(input.isPublic),
      participants,
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
