import { RemoveChatParticipantResult, RemoveChatParticipantInput } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { Method } from "@inline-chat/protocol/core"

export const method = Method.REMOVE_CHAT_PARTICIPANT

export const removeChatParticipant = async (
  input: RemoveChatParticipantInput,
  handlerContext: HandlerContext,
): Promise<RemoveChatParticipantResult> => {
  await Functions.messages.removeChatParticipant(
    {
      chatId: Number(input.chatId),
      userId: input.userId != null ? Number(input.userId) : undefined,
      groupId: input.groupId != null ? Number(input.groupId) : undefined,
    },
    {
      currentUserId: handlerContext.userId,
      currentSessionId: handlerContext.sessionId,
    },
  )

  return {}
}
