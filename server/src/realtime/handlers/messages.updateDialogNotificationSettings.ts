import {
  type UpdateDialogNotificationSettingsInput,
  type UpdateDialogNotificationSettingsResult,
} from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { updateDialogNotificationSettings as updateDialogNotificationSettingsFunction } from "@in/server/functions/messages.updateDialogNotificationSettings"

export const updateDialogNotificationSettings = async (
  input: UpdateDialogNotificationSettingsInput,
  handlerContext: HandlerContext,
): Promise<UpdateDialogNotificationSettingsResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const result = await updateDialogNotificationSettingsFunction(
    {
      peerId: input.peerId,
      notificationSettings: input.notificationSettings,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return {
    updates: result.updates,
  }
}

