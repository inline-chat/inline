import { GetChatParticipantsInput, GetChatParticipantsResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { Method } from "@in/protocol/core"

export const method = Method.GET_CHAT_PARTICIPANTS

export const getChatParticipants = async (
  input: GetChatParticipantsInput,
  handlerContext: HandlerContext,
): Promise<GetChatParticipantsResult> => {
  const result = await Functions.messages.getChatParticipants(
    {
      chatId: Number(input.chatId),
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )
  return result
}
