import { Method, ShowChatInSidebarInput, ShowChatInSidebarResult } from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"

export const method = Method.SHOW_CHAT_IN_SIDEBAR

export const showChatInSidebar = async (
  input: ShowChatInSidebarInput,
  handlerContext: HandlerContext,
): Promise<ShowChatInSidebarResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  return Functions.messages.showChatInSidebar(
    { peerId: input.peerId },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )
}
