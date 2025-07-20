import {
  MarkAsUnreadInput,
  MarkAsUnreadResult,
} from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { markAsUnread as markAsUnreadFunction } from "@in/server/functions/messages.markAsUnread"

export const markAsUnread = async (
  input: MarkAsUnreadInput,
  handlerContext: HandlerContext,
): Promise<MarkAsUnreadResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid
  }

  const result = await markAsUnreadFunction(
    { peer: input.peerId },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return { updates: result.updates }
} 