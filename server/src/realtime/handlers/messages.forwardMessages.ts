import { ForwardMessagesInput, ForwardMessagesResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { forwardMessages } from "@in/server/functions/messages.forwardMessages"
import { RealtimeRpcError } from "@in/server/realtime/errors"

export const forwardMessagesHandler = async (
  input: ForwardMessagesInput,
  handlerContext: HandlerContext,
): Promise<ForwardMessagesResult> => {
  if (!input.fromPeerId || !input.toPeerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  if (input.messageIds.length === 0) {
    throw RealtimeRpcError.BadRequest()
  }

  const result = await forwardMessages(
    {
      fromPeerId: input.fromPeerId,
      toPeerId: input.toPeerId,
      messageIds: input.messageIds,
      shareForwardHeader: input.shareForwardHeader,
    },
    {
      currentUserId: handlerContext.userId,
      currentSessionId: handlerContext.sessionId,
    },
  )

  return { updates: result.updates }
}
