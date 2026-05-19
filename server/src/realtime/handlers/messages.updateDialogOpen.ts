import { Method, UpdateDialogOpenInput, UpdateDialogOpenResult } from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

export const method = Method.UPDATE_DIALOG_OPEN

export const updateDialogOpen = async (
  input: UpdateDialogOpenInput,
  handlerContext: HandlerContext,
): Promise<UpdateDialogOpenResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  return Functions.messages.updateDialogOpen(
    { peerId: input.peerId, open: input.open },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )
}
