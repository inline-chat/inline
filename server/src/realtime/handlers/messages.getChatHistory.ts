import { GetChatHistoryInput, GetChatHistoryMode, GetChatHistoryResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Functions } from "@in/server/functions"

function resolveHistoryMode(input: GetChatHistoryInput): "latest" | "older" | "newer" | "around" | undefined {
  switch (input.mode) {
    case GetChatHistoryMode.HISTORY_MODE_LATEST:
      return "latest"
    case GetChatHistoryMode.HISTORY_MODE_OLDER:
      return "older"
    case GetChatHistoryMode.HISTORY_MODE_NEWER:
      return "newer"
    case GetChatHistoryMode.HISTORY_MODE_AROUND:
      return "around"
    case GetChatHistoryMode.HISTORY_MODE_UNSPECIFIED:
    case undefined:
      return undefined
    default:
      throw RealtimeRpcError.BadRequest()
  }
}

export const getChatHistory = async (
  input: GetChatHistoryInput,
  handlerContext: HandlerContext,
): Promise<GetChatHistoryResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const result = await Functions.messages.getChatHistory(
    {
      peerId: input.peerId,
      offsetId: input.offsetId,
      limit: input.limit,
      mode: resolveHistoryMode(input),
      anchorId: input.anchorId,
      beforeId: input.beforeId,
      afterId: input.afterId,
      beforeLimit: input.beforeLimit,
      afterLimit: input.afterLimit,
      includeAnchor: input.includeAnchor,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return { messages: result.messages }
}
