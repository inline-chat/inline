import { UserSettingsModel } from "@in/server/db/models/userSettings"
import { invalidateUserSettingsCache } from "@in/server/modules/cache/userSettings"
import type { FunctionContext } from "@in/server/functions/_types"
import type { UserSettingsGeneral, UserSettingsGeneralInput } from "@in/server/db/models/userSettings/types"
import type { Update } from "@in/protocol/core"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeUpdates } from "@in/server/realtime/message"

export interface UpdateUserSettingsInput {
  general?: UserSettingsGeneralInput
}

export interface UpdateUserSettingsResult {
  updates: Update[]
}

export const updateUserSettings = async (
  input: UpdateUserSettingsInput,
  context: FunctionContext,
): Promise<UpdateUserSettingsResult> => {
  let updatedGeneral: UserSettingsGeneral | undefined = undefined

  if (input.general) {
    updatedGeneral = await UserSettingsModel.updateGeneral(context.currentUserId, input.general)

    // Invalidate cache to ensure fresh data
    invalidateUserSettingsCache(context.currentUserId)
  }

  // For the update message, use the data we just set (if any) or fetch current data
  const generalForUpdate = updatedGeneral ?? (await UserSettingsModel.getGeneral(context.currentUserId))

  // Create update for user settings change
  const update: Update = {
    update: {
      oneofKind: "updateUserSettings",
      updateUserSettings: {
        settings: Encoders.userSettings({ general: generalForUpdate }),
      },
    },
  }

  // Push update to the current user in real-time
  RealtimeUpdates.pushToUser(context.currentUserId, [update])

  return {
    updates: [update],
  }
}
