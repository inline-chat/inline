import {
  DialogNotificationSettings,
  DialogNotificationSettings_Mode,
  type DialogNotificationSettings as DialogNotificationSettingsMessage,
} from "@inline-chat/protocol/core"
import {
  UserSettingsNotificationsMode,
  type UserSettingsGeneral,
} from "@in/server/db/models/userSettings/types"

export const decodeDialogNotificationSettings = (
  binary: Uint8Array | null | undefined,
): DialogNotificationSettingsMessage | undefined => {
  if (!binary || binary.length === 0) {
    return undefined
  }

  try {
    return DialogNotificationSettings.fromBinary(binary)
  } catch {
    return undefined
  }
}

export const encodeDialogNotificationSettings = (
  settings: DialogNotificationSettingsMessage | null | undefined,
): Uint8Array | null => {
  if (!settings) {
    return null
  }

  return DialogNotificationSettings.toBinary(settings)
}

export const isValidDialogNotificationMode = (mode: DialogNotificationSettings_Mode | undefined): boolean => {
  return (
    mode === DialogNotificationSettings_Mode.ALL ||
    mode === DialogNotificationSettings_Mode.MENTIONS ||
    mode === DialogNotificationSettings_Mode.NONE
  )
}

export const normalizeGlobalNotificationMode = (
  userSettings: UserSettingsGeneral | null | undefined,
): UserSettingsNotificationsMode | undefined => {
  const rawMode = userSettings?.notifications.mode
  if (!rawMode) {
    return undefined
  }

  const legacyOnlyMentions =
    rawMode === UserSettingsNotificationsMode.OnlyMentions ||
    (rawMode === UserSettingsNotificationsMode.Mentions && userSettings?.notifications.disableDmNotifications)
  return legacyOnlyMentions ? UserSettingsNotificationsMode.OnlyMentions : rawMode
}

export const resolveEffectiveNotificationMode = ({
  globalMode,
  dialogNotificationSettings,
}: {
  globalMode: UserSettingsNotificationsMode | undefined
  dialogNotificationSettings: DialogNotificationSettingsMessage | undefined
}): UserSettingsNotificationsMode | undefined => {
  const mode = dialogNotificationSettings?.mode
  if (mode == null) {
    return globalMode
  }

  switch (mode) {
    case DialogNotificationSettings_Mode.ALL:
      return UserSettingsNotificationsMode.All
    case DialogNotificationSettings_Mode.MENTIONS:
      return UserSettingsNotificationsMode.Mentions
    case DialogNotificationSettings_Mode.NONE:
      return UserSettingsNotificationsMode.None
    default:
      return globalMode
  }
}
