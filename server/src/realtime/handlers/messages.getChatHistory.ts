import { GetChatHistoryInput, GetChatHistoryResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Functions } from "@in/server/functions"

export const getChatHistory = async (
  input: GetChatHistoryInput,
  handlerContext: HandlerContext,
): Promise<GetChatHistoryResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid
  }

  const result = await Functions.messages.getChatHistory(
    {
      peerId: input.peerId,
      offsetId: input.offsetId,
      limit: input.limit,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return { messages: result.messages }
}
