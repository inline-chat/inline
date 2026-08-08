import { Functions } from "@in/server/functions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"
import type { CollapseHistoryInput, CollapseHistoryResult } from "@inline-chat/protocol/core"

export const collapseHistory = async (
  input: CollapseHistoryInput,
  handlerContext: HandlerContext,
): Promise<CollapseHistoryResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const maxId = input.maxId === undefined ? undefined : Number(input.maxId)
  if (maxId !== undefined && !Number.isSafeInteger(maxId)) {
    throw RealtimeRpcError.MessageIdInvalid()
  }

  return Functions.messages.collapseHistory(
    { peerId: input.peerId, maxId },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )
}
