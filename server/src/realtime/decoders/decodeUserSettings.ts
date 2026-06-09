import { type UserSettings } from "@inline-chat/protocol/core"
import type { UserSettingsGeneralInput } from "@in/server/db/models/userSettings/types"
import { decodeProtocolNotificationMode } from "@in/server/modules/notifications/notificationSettingsCompat"

export const decodeUserSettings = (userSettings?: UserSettings): UserSettingsGeneralInput | undefined => {
  if (!userSettings) {
    return undefined
  }

  const notificationSettings = userSettings.notificationSettings
  if (!notificationSettings) {
    return undefined
  }

  const { mode, disableDmNotifications } = decodeProtocolNotificationMode(notificationSettings)

  return {
    notifications: {
      mode,
      silent: notificationSettings.silent ?? false,
      disableDmNotifications,
    },
  }
}
