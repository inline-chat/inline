import { UserSettingsModel } from "@in/server/db/models/userSettings"
import { getCachedUserSettings, invalidateUserSettingsCache } from "@in/server/modules/cache/userSettings"
import type { FunctionContext } from "@in/server/functions/_types"
import type { UserSettingsGeneral, UserSettingsGeneralInput } from "@in/server/db/models/userSettings/types"
import { defaultNotificationSettings, UserSettingsGeneralSchema } from "@in/server/db/models/userSettings/types"
import type { Update } from "@inline-chat/protocol/core"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { normalizeUserSettingsGeneral } from "@in/server/modules/notifications/notificationSettingsCompat"

export interface UpdateUserSettingsInput {
  general?: UserSettingsGeneralInput
}

export interface UpdateUserSettingsResult {
  updates: Update[]
}

// Helper function to check if settings have changed using deep equality
function normalizedGeneral(current: UserSettingsGeneral | null, input: UserSettingsGeneralInput): UserSettingsGeneral {
  return normalizeUserSettingsGeneral(
    UserSettingsGeneralSchema.parse({
      notifications: {
        ...(current?.notifications ?? defaultNotificationSettings),
        ...input.notifications,
      },
    }),
  )
}

function hasSettingsChanged(current: UserSettingsGeneral | null, next: UserSettingsGeneral): boolean {
  if (!current) {
    return true // If no current settings exist, any input is a change
  }
  // Compare the normalized structures using JSON serialization
  // This approach is resilient to schema changes as it compares the actual data
  return JSON.stringify(current) !== JSON.stringify(next)
}

export const updateUserSettings = async (
  input: UpdateUserSettingsInput,
  context: FunctionContext,
): Promise<UpdateUserSettingsResult> => {
  let updatedGeneral: UserSettingsGeneral | undefined = undefined
  let hasChanges = false

  if (input.general) {
    // Get current settings to compare
    const currentGeneral = await getCachedUserSettings(context.currentUserId)
    const nextGeneral = normalizedGeneral(currentGeneral, input.general)

    // Check if settings have actually changed
    if (hasSettingsChanged(currentGeneral, nextGeneral)) {
      updatedGeneral = await UserSettingsModel.updateGeneral(context.currentUserId, nextGeneral)
      hasChanges = true

      // Invalidate cache to ensure fresh data
      invalidateUserSettingsCache(context.currentUserId)
    }
  }

  // Only create and send updates if there were actual changes
  if (!hasChanges) {
    return {
      updates: [],
    }
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
  RealtimeUpdates.pushToUser(context.currentUserId, [update], { skipSessionId: context.currentSessionId })

  return {
    updates: [update],
  }
}
