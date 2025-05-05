import type { DeleteChatInput, DeleteChatResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { deleteChat } from "@in/server/functions/messages.deleteChat"
import { Log } from "@in/server/utils/log"
import { RealtimeRpcError } from "@in/server/realtime/errors"

const log = new Log("handlers.deleteChat")

export async function deleteChatHandler(
  input: DeleteChatInput,
  handlerContext: HandlerContext,
): Promise<DeleteChatResult> {
  try {
    if (!input.peerId) {
      throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "peerId is required", 400)
    }
    const {} = await deleteChat(
      { peer: input.peerId },
      {
        currentUserId: handlerContext.userId,
        currentSessionId: handlerContext.sessionId,
      },
    )
    return {}
  } catch (err) {
    log.error("Failed to delete chat", { error: err })
    if (err instanceof RealtimeRpcError) throw err
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to delete chat", 500)
  }
}
