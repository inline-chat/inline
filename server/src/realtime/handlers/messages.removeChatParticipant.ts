import {
  AddChatParticipantInput,
  AddChatParticipantResult,
  RemoveChatParticipantResult,
  RemoveChatParticipantInput,
} from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { Method } from "@in/protocol/core"

export const method = Method.REMOVE_CHAT_PARTICIPANT

export const removeChatParticipant = async (
  input: RemoveChatParticipantInput,
  handlerContext: HandlerContext,
): Promise<RemoveChatParticipantResult> => {
  await Functions.messages.removeChatParticipant(
    {
      chatId: Number(input.chatId),
      userId: Number(input.userId),
    },
    {
      currentUserId: handlerContext.userId,
      currentSessionId: handlerContext.sessionId,
    },
  )

  return {}
}
