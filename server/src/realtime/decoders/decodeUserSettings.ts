import { type UserSettings } from "@inline-chat/protocol/core"
import { MessageGestureSettingsSchema, type UserSettingsGeneralInput } from "@in/server/db/models/userSettings/types"
import { decodeProtocolNotificationMode } from "@in/server/modules/notifications/notificationSettingsCompat"

export const decodeUserSettings = (userSettings?: UserSettings): UserSettingsGeneralInput | undefined => {
  if (!userSettings) {
    return undefined
  }

  const notificationSettings = userSettings.notificationSettings
  const privacySettings = userSettings.privacySettings
  const messageGestures = userSettings.messageGestureSettings
  const composeSettings = userSettings.composeSettings
  if (!notificationSettings && !privacySettings && !composeSettings && !messageGestures) {
    return undefined
  }

  const notifications = notificationSettings
    ? (() => {
        const { mode, disableDmNotifications } = decodeProtocolNotificationMode(notificationSettings)
        return {
          mode,
          silent: notificationSettings.silent ?? false,
          disableDmNotifications,
        }
      })()
    : undefined

  return {
    notifications,
    messageGestures: messageGestures ? MessageGestureSettingsSchema.parse(messageGestures) : undefined,
    privacy: privacySettings
      ? {
          shareTimeZone: privacySettings.shareTimeZone ?? true,
          appearInGlobalSearch: privacySettings.appearInGlobalSearch ?? true,
        }
      : undefined,
    compose: composeSettings
      ? {
          replacePastedLinksWithTitles: composeSettings.replacePastedLinksWithTitles ?? false,
        }
      : undefined,
  }
}
