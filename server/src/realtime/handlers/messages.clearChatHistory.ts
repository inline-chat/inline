import type { ClearChatHistoryInput, ClearChatHistoryResult } from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

export const clearChatHistoryHandler = async (
  input: ClearChatHistoryInput,
  handlerContext: HandlerContext,
): Promise<ClearChatHistoryResult> => {
  if (!input.target) {
    throw RealtimeRpcError.BadRequest()
  }

  const context = {
    currentUserId: handlerContext.userId,
    currentSessionId: handlerContext.sessionId,
  }

  switch (input.target.oneofKind) {
    case "peerId": {
      const result = await Functions.messages.clearChatHistory(
        {
          peer: input.target.peerId,
          keepLastDays: input.keepLastDays,
          deleteReplyThreads: input.deleteReplyThreads,
        },
        context,
      )
      return { updates: result.updates }
    }
    case "spaceId": {
      const result = await Functions.messages.clearChatHistory(
        {
          spaceId: Number(input.target.spaceId),
          keepLastDays: input.keepLastDays,
          deleteReplyThreads: input.deleteReplyThreads,
        },
        context,
      )
      return { updates: result.updates }
    }
    default:
      throw RealtimeRpcError.BadRequest()
  }
}
