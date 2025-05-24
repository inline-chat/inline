import { type GetUserSettingsInput, type GetUserSettingsResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { Encoders } from "@in/server/realtime/encoders/encoders"

export const getUserSettingsHandler = async (
  input: GetUserSettingsInput,
  handlerContext: HandlerContext,
): Promise<GetUserSettingsResult> => {
  const result = await Functions.user.getUserSettings(
    {},
    {
      currentUserId: handlerContext.userId,
      currentSessionId: handlerContext.sessionId,
    },
  )

  return {
    userSettings: Encoders.userSettings({ general: result.general }),
  }
}
