import { NotificationSettings_Mode, type NotificationSettings } from "@inline-chat/protocol/core"
import {
  UserSettingsNotificationsMode,
  type UserSettingsGeneral,
} from "@in/server/db/models/userSettings/types"

export const normalizeNotificationMode = (
  mode: UserSettingsNotificationsMode | undefined,
): UserSettingsNotificationsMode | undefined => {
  if (mode === UserSettingsNotificationsMode.ImportantOnly) {
    return UserSettingsNotificationsMode.Mentions
  }

  return mode
}

export const normalizeUserSettingsGeneral = (general: UserSettingsGeneral): UserSettingsGeneral => {
  const mode = normalizeNotificationMode(general.notifications.mode)
  if (mode === general.notifications.mode) {
    return general
  }

  return {
    ...general,
    notifications: {
      ...general.notifications,
      mode: mode ?? UserSettingsNotificationsMode.All,
      disableDmNotifications: false,
    },
  }
}

export const decodeProtocolNotificationMode = (
  settings: NotificationSettings,
): {
  mode: UserSettingsNotificationsMode
  disableDmNotifications: boolean
} => {
  if (settings.mode === NotificationSettings_Mode.IMPORTANT_ONLY) {
    return {
      mode: UserSettingsNotificationsMode.Mentions,
      disableDmNotifications: false,
    }
  }

  const legacyDisableDmNotifications = settings.disableDmNotifications ?? false
  const disableDmNotifications =
    legacyDisableDmNotifications || settings.mode === NotificationSettings_Mode.ONLY_MENTIONS

  switch (settings.mode) {
    case NotificationSettings_Mode.ALL:
      return {
        mode: UserSettingsNotificationsMode.All,
        disableDmNotifications: false,
      }
    case NotificationSettings_Mode.NONE:
      return {
        mode: UserSettingsNotificationsMode.None,
        disableDmNotifications: false,
      }
    case NotificationSettings_Mode.MENTIONS:
      return {
        mode: disableDmNotifications
          ? UserSettingsNotificationsMode.OnlyMentions
          : UserSettingsNotificationsMode.Mentions,
        disableDmNotifications,
      }
    case NotificationSettings_Mode.ONLY_MENTIONS:
      return {
        mode: UserSettingsNotificationsMode.OnlyMentions,
        disableDmNotifications: true,
      }
    default:
      return {
        mode: UserSettingsNotificationsMode.All,
        disableDmNotifications: false,
      }
  }
}

export const encodeProtocolNotificationMode = (
  mode: UserSettingsNotificationsMode,
  disableDmNotifications: boolean,
): {
  mode: NotificationSettings_Mode
  disableDmNotifications: boolean
} => {
  if (mode === UserSettingsNotificationsMode.ImportantOnly) {
    return {
      mode: NotificationSettings_Mode.MENTIONS,
      disableDmNotifications: false,
    }
  }

  switch (normalizeNotificationMode(mode)) {
    case UserSettingsNotificationsMode.All:
      return {
        mode: NotificationSettings_Mode.ALL,
        disableDmNotifications,
      }
    case UserSettingsNotificationsMode.None:
      return {
        mode: NotificationSettings_Mode.NONE,
        disableDmNotifications,
      }
    case UserSettingsNotificationsMode.Mentions:
      return {
        mode: NotificationSettings_Mode.MENTIONS,
        disableDmNotifications,
      }
    case UserSettingsNotificationsMode.OnlyMentions:
      return {
        mode: NotificationSettings_Mode.MENTIONS,
        disableDmNotifications: true,
      }
    default:
      return {
        mode: NotificationSettings_Mode.UNSPECIFIED,
        disableDmNotifications,
      }
  }
}

export const normalizeGlobalNotificationMode = (
  userSettings: UserSettingsGeneral | null | undefined,
): UserSettingsNotificationsMode | undefined => {
  const rawMode = userSettings?.notifications.mode
  if (rawMode === UserSettingsNotificationsMode.ImportantOnly) {
    return UserSettingsNotificationsMode.Mentions
  }

  const mode = normalizeNotificationMode(rawMode)
  if (!mode) {
    return undefined
  }

  const legacyOnlyMentions =
    mode === UserSettingsNotificationsMode.OnlyMentions ||
    (mode === UserSettingsNotificationsMode.Mentions && userSettings?.notifications.disableDmNotifications)
  return legacyOnlyMentions ? UserSettingsNotificationsMode.OnlyMentions : mode
}
