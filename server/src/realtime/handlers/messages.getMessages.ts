import { GetMessagesInput, GetMessagesResult } from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

export const getMessages = async (
  input: GetMessagesInput,
  handlerContext: HandlerContext,
): Promise<GetMessagesResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const result = await Functions.messages.getMessages(
    {
      peerId: input.peerId,
      messageIds: input.messageIds,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return { messages: result.messages }
}
