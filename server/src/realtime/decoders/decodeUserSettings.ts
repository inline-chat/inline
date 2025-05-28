import { type UserSettings } from "@in/protocol/core"
import { NotificationSettings_Mode } from "@in/protocol/core"
import { UserSettingsNotificationsMode } from "@in/server/db/models/userSettings/types"
import type { UserSettingsGeneralInput } from "@in/server/db/models/userSettings/types"

export const decodeUserSettings = (userSettings?: UserSettings): UserSettingsGeneralInput | undefined => {
  if (!userSettings?.notificationSettings) {
    return undefined
  }

  const notificationSettings = userSettings.notificationSettings

  let mode: UserSettingsNotificationsMode
  switch (notificationSettings.mode) {
    case NotificationSettings_Mode.ALL:
      mode = UserSettingsNotificationsMode.All
      break
    case NotificationSettings_Mode.NONE:
      mode = UserSettingsNotificationsMode.None
      break
    case NotificationSettings_Mode.MENTIONS:
      mode = UserSettingsNotificationsMode.Mentions
      break
    case NotificationSettings_Mode.IMPORTANT_ONLY:
      mode = UserSettingsNotificationsMode.ImportantOnly
      break
    default:
      mode = UserSettingsNotificationsMode.All // Default fallback
      break
  }

  return {
    notifications: {
      mode,
      silent: notificationSettings.silent ?? false,
      zenModeRequiresMention: notificationSettings.zenModeRequiresMention ?? true,
      zenModeUsesDefaultRules: notificationSettings.zenModeUsesDefaultRules ?? true,
      zenModeCustomRules: notificationSettings.zenModeCustomRules ?? "",
    },
  }
}
