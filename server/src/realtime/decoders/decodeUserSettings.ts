import { PrivacyRule_Audience, type PrivacyRule, type UserSettings } from "@inline-chat/protocol/core"
import {
  MessageGestureSettingsSchema,
  PRIVACY_RULE_MAX_TARGETS,
  type PrivacyRuleInput,
  type UserSettingsGeneralInput,
} from "@in/server/db/models/userSettings/types"
import type { PrivacyPatch } from "@in/server/modules/privacy/privacyRules"
import { RealtimeRpcError } from "@in/server/realtime/errors"
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
    privacy: privacySettings ? decodePrivacyPatch(privacySettings) : undefined,
    compose: composeSettings
      ? {
          replacePastedLinksWithTitles: composeSettings.replacePastedLinksWithTitles ?? false,
        }
      : undefined,
  }
}

/** Absent fields stay absent so a partial save leaves them unchanged. */
const decodePrivacyPatch = (settings: NonNullable<UserSettings["privacySettings"]>): PrivacyPatch => {
  const patch: PrivacyPatch = {}
  if (settings.shareTimeZone !== undefined) patch.shareTimeZone = settings.shareTimeZone
  if (settings.appearInGlobalSearch !== undefined) patch.appearInGlobalSearch = settings.appearInGlobalSearch
  if (settings.timeZone) patch.timeZone = decodePrivacyRule(settings.timeZone)
  return patch
}

export const decodePrivacyRule = (rule: PrivacyRule): PrivacyRuleInput => {
  const audience =
    rule.audience === PrivacyRule_Audience.EVERYONE
      ? "everyone"
      : rule.audience === PrivacyRule_Audience.NOBODY
        ? "nobody"
        : undefined
  if (!audience) throw RealtimeRpcError.BadRequest()
  if (rule.alwaysShare.length > PRIVACY_RULE_MAX_TARGETS || rule.neverShare.length > PRIVACY_RULE_MAX_TARGETS) {
    throw RealtimeRpcError.BadRequest()
  }

  // Target kinds this server does not know are dropped.
  const userIds = (targets: PrivacyRule["alwaysShare"]) =>
    targets.flatMap((target) => (target.target.oneofKind === "userId" ? [Number(target.target.userId)] : []))

  return { audience, alwaysShare: userIds(rule.alwaysShare), neverShare: userIds(rule.neverShare) }
}
