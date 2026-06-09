import type { UserSettings, NotificationSettings } from "@inline-chat/protocol/core"
import type { UserSettingsGeneral } from "@in/server/db/models/userSettings/types"
import { encodeProtocolNotificationMode } from "@in/server/modules/notifications/notificationSettingsCompat"

export const encodeUserSettings = ({ general }: { general?: UserSettingsGeneral | null }): UserSettings => {
  let notificationSettings: NotificationSettings | undefined = undefined

  if (general?.notifications) {
    const { mode, disableDmNotifications } = encodeProtocolNotificationMode(
      general.notifications.mode,
      general.notifications.disableDmNotifications,
    )

    notificationSettings = {
      mode,
      silent: general.notifications.silent,
      disableDmNotifications,
    }
  }

  return {
    notificationSettings,
  }
}
