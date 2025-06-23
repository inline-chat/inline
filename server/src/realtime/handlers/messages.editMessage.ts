import { EditMessageInput, EditMessageResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Functions } from "@in/server/functions"

export const editMessage = async (
  input: EditMessageInput,
  handlerContext: HandlerContext,
): Promise<EditMessageResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid
  }

  const result = await Functions.messages.editMessage(
    { messageId: input.messageId, peer: input.peerId, text: input.text, entities: input.entities },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return { updates: result.updates }
}
