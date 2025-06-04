import type { SendComposeActionInput, SendComposeActionResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { sendComposeAction } from "@in/server/functions/messages.sendComposeAction"

export const sendComposeActionHandler = async (
  input: SendComposeActionInput,
  handlerContext: HandlerContext,
): Promise<SendComposeActionResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid
  }

  await sendComposeAction(
    { peer: input.peerId, action: input.action },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return {}
}
