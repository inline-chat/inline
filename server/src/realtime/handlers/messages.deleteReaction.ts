import { DeleteReactionInput, DeleteReactionResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Functions } from "@in/server/functions"

export const deleteReaction = async (
  input: DeleteReactionInput,
  handlerContext: HandlerContext,
): Promise<DeleteReactionResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const result = await Functions.messages.deleteReaction(
    { messageId: input.messageId, emoji: input.emoji, peer: input.peerId },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return { updates: result.updates }
}
