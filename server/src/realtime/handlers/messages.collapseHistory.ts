import type { CollapseHistoryInput, CollapseHistoryResult } from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

export const collapseHistoryHandler = async (
  input: CollapseHistoryInput,
  handlerContext: HandlerContext,
): Promise<CollapseHistoryResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  return Functions.messages.collapseHistory(
    {
      peerId: input.peerId,
      maxId: input.maxId,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )
}
