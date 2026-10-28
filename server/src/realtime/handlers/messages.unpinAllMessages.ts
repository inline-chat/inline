import { UnpinAllMessagesInput, UnpinAllMessagesResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { unpinAllMessages } from "@in/server/functions/messages.unpinAllMessages"

export const unpinAllMessagesHandler = async (
  input: UnpinAllMessagesInput,
  handlerContext: HandlerContext,
): Promise<UnpinAllMessagesResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const result = await unpinAllMessages(
    { peer: input.peerId },
    {
      currentUserId: handlerContext.userId,
      currentSessionId: handlerContext.sessionId,
    },
  )

  return { updates: result.updates }
}
