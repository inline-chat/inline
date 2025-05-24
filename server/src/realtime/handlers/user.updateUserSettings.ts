import { type UpdateUserSettingsInput, type UpdateUserSettingsResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { decodeUserSettings } from "@in/server/realtime/decoders/decodeUserSettings"

export const updateUserSettingsHandler = async (
  input: UpdateUserSettingsInput,
  handlerContext: HandlerContext,
): Promise<UpdateUserSettingsResult> => {
  const general = decodeUserSettings(input.userSettings)

  const result = await Functions.user.updateUserSettings(
    { general },
    {
      currentUserId: handlerContext.userId,
      currentSessionId: handlerContext.sessionId,
    },
  )

  return {
    updates: result.updates,
  }
}
