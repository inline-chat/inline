import { UpdateNewMessageNotification_Reason } from "@inline-chat/protocol/core"
import { UserSettingsNotificationsMode } from "@in/server/db/models/userSettings/types"
import { normalizeNotificationMode } from "@in/server/modules/notifications/notificationSettingsCompat"

export type NotificationDecisionInput = {
  mode: UserSettingsNotificationsMode | undefined
  isUrgentNudge: boolean
  isNudge: boolean
  isDM: boolean
  isReplyToUser: boolean
  isExplicitlyMentioned: boolean
}

export type NotificationDecision = {
  shouldNotify: boolean
  needsExplicitMacNotification: boolean
  reason: UpdateNewMessageNotification_Reason
}

export const decideNotification = (input: NotificationDecisionInput): NotificationDecision => {
  const {
    mode: rawMode,
    isUrgentNudge,
    isNudge,
    isDM,
    isReplyToUser,
    isExplicitlyMentioned,
  } = input
  const mode = normalizeNotificationMode(rawMode)

  if (mode === UserSettingsNotificationsMode.None && !isUrgentNudge) {
    return {
      shouldNotify: false,
      needsExplicitMacNotification: false,
      reason: UpdateNewMessageNotification_Reason.UNSPECIFIED,
    }
  }

  if (isDM && mode === UserSettingsNotificationsMode.OnlyMentions && !isNudge && !isExplicitlyMentioned) {
    return {
      shouldNotify: false,
      needsExplicitMacNotification: false,
      reason: UpdateNewMessageNotification_Reason.UNSPECIFIED,
    }
  }

  const countsDmAsMention = mode !== UserSettingsNotificationsMode.OnlyMentions
  const isMentioned = isExplicitlyMentioned || isReplyToUser || (countsDmAsMention && isDM)
  const requiresNotification = isNudge

  if (mode === UserSettingsNotificationsMode.Mentions || mode === UserSettingsNotificationsMode.OnlyMentions) {
    if (!isMentioned && !requiresNotification && !(mode === UserSettingsNotificationsMode.Mentions && isDM)) {
      return {
        shouldNotify: false,
        needsExplicitMacNotification: false,
        reason: UpdateNewMessageNotification_Reason.UNSPECIFIED,
      }
    }

    return {
      shouldNotify: true,
      needsExplicitMacNotification: true,
      reason: UpdateNewMessageNotification_Reason.MENTION,
    }
  }

  return {
    shouldNotify: true,
    needsExplicitMacNotification: false,
    reason: UpdateNewMessageNotification_Reason.UNSPECIFIED,
  }
}
