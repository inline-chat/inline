import {
  type UpdateDialogFollowModeInput,
  type UpdateDialogFollowModeResult,
} from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

export const updateDialogFollowMode = async (
  input: UpdateDialogFollowModeInput,
  handlerContext: HandlerContext,
): Promise<UpdateDialogFollowModeResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  return Functions.messages.updateDialogFollowMode(
    {
      peerId: input.peerId,
      followMode: input.followMode,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )
}
