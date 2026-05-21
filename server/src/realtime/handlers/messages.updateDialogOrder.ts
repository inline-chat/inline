import { Method, UpdateDialogOrderInput, UpdateDialogOrderResult } from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

export const method = Method.UPDATE_DIALOG_ORDER

export const updateDialogOrder = async (
  input: UpdateDialogOrderInput,
  handlerContext: HandlerContext,
): Promise<UpdateDialogOrderResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  return Functions.messages.updateDialogOrder(
    {
      peerId: input.peerId,
      order: input.order,
      pinnedOrder: input.pinnedOrder,
      pinned: input.pinned,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )
}
