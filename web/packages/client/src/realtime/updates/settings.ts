import {
  NotificationSettings_Mode,
  type NotificationSettings,
  type SpaceSettings,
  type UserSettings as ProtocolUserSettings,
} from "@inline-chat/protocol/core"
import { spaceId } from "@inline/ids"
import type { Db } from "../../database"
import {
  DbObjectKind,
  type NotificationMode,
  type UserSettings,
} from "../../database/models"

/*
 * The account's settings (`updateUserSettings`, `GET_USER_SETTINGS`,
 * `UPDATE_USER_SETTINGS`) as one typed row, and a space's settings.
 */

export const USER_SETTINGS_ID = 0 as const

const notificationMode = (
  mode: NotificationSettings_Mode | undefined,
): NotificationMode | undefined => {
  switch (mode) {
    case NotificationSettings_Mode.ALL:
      return "all"
    case NotificationSettings_Mode.NONE:
      return "none"
    case NotificationSettings_Mode.MENTIONS:
      return "mentions"
    case NotificationSettings_Mode.IMPORTANT_ONLY:
      return "importantOnly"
    case NotificationSettings_Mode.ONLY_MENTIONS:
      return "onlyMentions"
    default:
      return undefined
  }
}

const protocolNotificationMode = (
  mode: NotificationMode | undefined,
): NotificationSettings_Mode | undefined => {
  switch (mode) {
    case "all":
      return NotificationSettings_Mode.ALL
    case "none":
      return NotificationSettings_Mode.NONE
    case "mentions":
      return NotificationSettings_Mode.MENTIONS
    case "importantOnly":
      return NotificationSettings_Mode.IMPORTANT_ONLY
    case "onlyMentions":
      return NotificationSettings_Mode.ONLY_MENTIONS
    default:
      return undefined
  }
}

/** Drop undefined keys so the stored row has no noise. */
const defined = <T extends Record<string, unknown>>(value: T): T =>
  Object.fromEntries(
    Object.entries(value).filter(([, entry]) => entry !== undefined),
  ) as T

const notifications = (
  settings: NotificationSettings,
): NonNullable<UserSettings["notifications"]> =>
  defined({
    mode: notificationMode(settings.mode),
    silent: settings.silent,
    zenModeRequiresMention: settings.zenModeRequiresMention,
    zenModeUsesDefaultRules: settings.zenModeUsesDefaultRules,
    zenModeCustomRules: settings.zenModeCustomRules,
    disableDmNotifications: settings.disableDmNotifications,
  })

/**
 * Merge server settings into the stored row. A group the server sent
 * replaces the stored group; a group it left out is kept.
 */
export const mergeUserSettings = (
  existing: UserSettings | undefined,
  settings: ProtocolUserSettings,
): UserSettings => ({
  ...(existing ?? { kind: DbObjectKind.UserSettings, id: USER_SETTINGS_ID }),
  ...(settings.notificationSettings
    ? { notifications: notifications(settings.notificationSettings) }
    : {}),
  ...(settings.privacySettings
    ? {
        privacy: defined({
          shareTimeZone: settings.privacySettings.shareTimeZone,
          appearInGlobalSearch: settings.privacySettings.appearInGlobalSearch,
          timeZone: settings.privacySettings.timeZone,
          focusStatus: settings.privacySettings.focusStatus,
        }),
      }
    : {}),
  ...(settings.composeSettings
    ? {
        compose: defined({
          replacePastedLinksWithTitles:
            settings.composeSettings.replacePastedLinksWithTitles,
        }),
      }
    : {}),
  ...(settings.messageGestureSettings
    ? {
        messageGestures: defined({
          doubleTapAction: settings.messageGestureSettings.doubleTapAction,
          holdAction: settings.messageGestureSettings.holdAction,
          swipeToReplyDirection:
            settings.messageGestureSettings.swipeToReplyDirection,
        }),
      }
    : {}),
})

export const userSettingsRef = (db: Db) =>
  db.ref(DbObjectKind.UserSettings, USER_SETTINGS_ID)

export const readUserSettings = (db: Db): UserSettings | undefined =>
  db.get(userSettingsRef(db))

export const applyUserSettings = (db: Db, settings: ProtocolUserSettings) => {
  db.replace(mergeUserSettings(readUserSettings(db), settings))
}

/** The protocol form of a settings patch, for `UPDATE_USER_SETTINGS`. */
export type UserSettingsPatch = Partial<
  Pick<UserSettings, "notifications" | "privacy" | "compose" | "messageGestures">
>

export const protocolUserSettings = (
  patch: UserSettingsPatch,
): ProtocolUserSettings => ({
  ...(patch.notifications
    ? {
        notificationSettings: defined({
          mode: protocolNotificationMode(patch.notifications.mode),
          silent: patch.notifications.silent,
          zenModeRequiresMention: patch.notifications.zenModeRequiresMention,
          zenModeUsesDefaultRules: patch.notifications.zenModeUsesDefaultRules,
          zenModeCustomRules: patch.notifications.zenModeCustomRules,
          disableDmNotifications: patch.notifications.disableDmNotifications,
        }),
      }
    : {}),
  ...(patch.privacy ? { privacySettings: defined({ ...patch.privacy }) } : {}),
  ...(patch.compose ? { composeSettings: defined({ ...patch.compose }) } : {}),
  ...(patch.messageGestures
    ? { messageGestureSettings: defined({ ...patch.messageGestures }) }
    : {}),
})

/** Overlay a local patch on the stored settings (the optimistic value). */
export const patchUserSettings = (
  existing: UserSettings | undefined,
  patch: UserSettingsPatch,
): UserSettings => {
  const base = existing ?? {
    kind: DbObjectKind.UserSettings,
    id: USER_SETTINGS_ID,
  }
  return {
    ...base,
    ...(patch.notifications
      ? { notifications: { ...base.notifications, ...defined(patch.notifications) } }
      : {}),
    ...(patch.privacy
      ? { privacy: { ...base.privacy, ...defined(patch.privacy) } }
      : {}),
    ...(patch.compose
      ? { compose: { ...base.compose, ...defined(patch.compose) } }
      : {}),
    ...(patch.messageGestures
      ? { messageGestures: { ...base.messageGestures, ...defined(patch.messageGestures) } }
      : {}),
  }
}

/** Apply space settings to a stored space; a space not stored is left alone. */
export const applySpaceSettings = (db: Db, settings: SpaceSettings) => {
  const space = db.get(
    db.ref(DbObjectKind.Space, spaceId(settings.spaceId)),
  )
  if (!space) return false
  db.replace({ ...space, gridEnabled: settings.gridEnabled })
  return true
}
