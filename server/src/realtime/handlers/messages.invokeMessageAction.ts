import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Functions } from "@in/server/functions"
import type { InvokeMessageActionInput, InvokeMessageActionResult } from "@inline-chat/protocol/core"

export const invokeMessageAction = async (
  input: InvokeMessageActionInput,
  handlerContext: HandlerContext,
): Promise<InvokeMessageActionResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const result = await Functions.messages.invokeMessageAction(
    {
      peerId: input.peerId,
      messageId: input.messageId,
      actionId: input.actionId,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return {
    interactionId: result.interactionId,
  }
}
