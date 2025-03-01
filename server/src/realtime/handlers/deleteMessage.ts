import { UsersModel } from "@in/server/db/models/users"
import { DeleteMessagesInput, DeleteMessagesResult, type GetMeInput, type GetMeResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Functions } from "@in/server/functions"

export const deleteMessage = async (
  input: DeleteMessagesInput,
  handlerContext: HandlerContext,
): Promise<DeleteMessagesResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid
  }

  const result = await Functions.messages.deleteMessage(
    { messageIds: input.messageIds, peer: input.peerId },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return { updates: result.updates }
}
