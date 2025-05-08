import { AddChatParticipantInput, AddChatParticipantResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { Method } from "@in/protocol/core"

export const method = Method.ADD_CHAT_PARTICIPANT

export const addChatParticipant = async (
  input: AddChatParticipantInput,
  handlerContext: HandlerContext,
): Promise<AddChatParticipantResult> => {
  await Functions.messages.addChatParticipant(
    {
      chatId: Number(input.chatId),
      userId: Number(input.userId),
    },
    {
      currentUserId: handlerContext.userId,
      currentSessionId: handlerContext.sessionId,
    },
  )

  return {
    participant: {
      userId: BigInt(input.userId),
      date: BigInt(Date.now()),
    },
  }
}
