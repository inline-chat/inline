import { AddChatParticipantInput, AddChatParticipantResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { Method } from "@inline-chat/protocol/core"

export const method = Method.ADD_CHAT_PARTICIPANT

export const addChatParticipant = async (
  input: AddChatParticipantInput,
  handlerContext: HandlerContext,
): Promise<AddChatParticipantResult> => {
  return Functions.messages.addChatParticipant(
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
}
