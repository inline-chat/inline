import {
  PrivacyRule_Audience,
  type NotificationSettings,
  type PrivacyRule as ProtocolPrivacyRule,
  type UserSettings,
} from "@inline-chat/protocol/core"
import {
  defaultComposeSettings,
  defaultPrivacySettings,
  type PrivacyRule,
  type UserSettingsGeneral,
} from "@in/server/db/models/userSettings/types"
import { effectiveFocusRule, effectiveTimeZoneRule, legacyShareFlag } from "@in/server/modules/privacy/privacyRules"
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

  const timeZoneRule = effectiveTimeZoneRule(general?.privacy ?? defaultPrivacySettings)

  return {
    notificationSettings,
    messageGestureSettings: general?.messageGestures,
    privacySettings: {
      shareTimeZone: legacyShareFlag(timeZoneRule),
      appearInGlobalSearch:
        general?.privacy.appearInGlobalSearch ?? defaultPrivacySettings.appearInGlobalSearch,
      timeZone: encodePrivacyRule(timeZoneRule),
      focusStatus: encodePrivacyRule(effectiveFocusRule(general?.privacy)),
    },
    composeSettings: {
      replacePastedLinksWithTitles:
        general?.compose.replacePastedLinksWithTitles ?? defaultComposeSettings.replacePastedLinksWithTitles,
    },
  }
}

export const encodePrivacyRule = (rule: PrivacyRule): ProtocolPrivacyRule => {
  const targets = (ids: number[]) =>
    ids.map((id) => ({ target: { oneofKind: "userId" as const, userId: BigInt(id) } }))
  return {
    audience: rule.audience === "everyone" ? PrivacyRule_Audience.EVERYONE : PrivacyRule_Audience.NOBODY,
    alwaysShare: targets(rule.alwaysShare),
    neverShare: targets(rule.neverShare),
  }
}
