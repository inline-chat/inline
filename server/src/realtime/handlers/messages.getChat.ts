import { GetChatInput, GetChatResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Functions } from "@in/server/functions"

export const getChat = async (input: GetChatInput, handlerContext: HandlerContext): Promise<GetChatResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const result = await Functions.messages.getChat(
    {
      peerId: input.peerId,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return { chat: result.chat, dialog: result.dialog }
}
