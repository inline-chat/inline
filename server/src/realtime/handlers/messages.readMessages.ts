import { ReadMessagesInput, ReadMessagesResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { readMessages as readMessagesFunction } from "@in/server/functions/messages.readMessages"

export const readMessages = async (
  input: ReadMessagesInput,
  handlerContext: HandlerContext,
): Promise<ReadMessagesResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const result = await readMessagesFunction(
    {
      peer: input.peerId,
      maxId: input.maxId !== undefined ? Number(input.maxId) : undefined,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return { updates: result.updates }
}
