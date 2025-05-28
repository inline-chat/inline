import type { UserSettings, NotificationSettings } from "@in/protocol/core"
import { NotificationSettings_Mode } from "@in/protocol/core"
import type { UserSettingsGeneral } from "@in/server/db/models/userSettings/types"
import { UserSettingsNotificationsMode } from "@in/server/db/models/userSettings/types"

export const encodeUserSettings = ({ general }: { general?: UserSettingsGeneral | null }): UserSettings => {
  let notificationSettings: NotificationSettings | undefined = undefined

  if (general?.notifications) {
    let mode: NotificationSettings_Mode
    switch (general.notifications.mode) {
      case UserSettingsNotificationsMode.All:
        mode = NotificationSettings_Mode.ALL
        break
      case UserSettingsNotificationsMode.None:
        mode = NotificationSettings_Mode.NONE
        break
      case UserSettingsNotificationsMode.Mentions:
        mode = NotificationSettings_Mode.MENTIONS
        break
      case UserSettingsNotificationsMode.ImportantOnly:
        mode = NotificationSettings_Mode.IMPORTANT_ONLY
        break
      default:
        mode = NotificationSettings_Mode.UNSPECIFIED
        break
    }

    notificationSettings = {
      mode,
      silent: general.notifications.silent,
      zenModeRequiresMention: general.notifications.zenModeRequiresMention,
      zenModeUsesDefaultRules: general.notifications.zenModeUsesDefaultRules,
      zenModeCustomRules: general.notifications.zenModeCustomRules,
    }
  }

  return {
    notificationSettings,
  }
}
