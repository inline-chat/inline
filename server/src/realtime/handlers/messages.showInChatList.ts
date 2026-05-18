import { Method, ShowInChatListInput, ShowInChatListResult } from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"

export const method = Method.SHOW_IN_CHAT_LIST

export const showInChatList = async (
  input: ShowInChatListInput,
  handlerContext: HandlerContext,
): Promise<ShowInChatListResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  return Functions.messages.showInChatList(
    { peerId: input.peerId },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )
}
