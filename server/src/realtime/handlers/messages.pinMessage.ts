import { PinMessageInput, PinMessageResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { pinMessage } from "@in/server/functions/messages.pinMessage"

export const pinMessageHandler = async (
  input: PinMessageInput,
  handlerContext: HandlerContext,
): Promise<PinMessageResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  if (!input.messageId) {
    throw RealtimeRpcError.MessageIdInvalid()
  }

  const result = await pinMessage(
    {
      peer: input.peerId,
      messageId: input.messageId,
      unpin: input.unpin,
    },
    {
      currentUserId: handlerContext.userId,
      currentSessionId: handlerContext.sessionId,
    },
  )

  return { updates: result.updates }
}
