import { z } from "zod/v4"

export enum UserSettingsNotificationsMode {
  All = "1",
  None = "2",
  Mentions = "3",
  ImportantOnly = "4",
  OnlyMentions = "5",
}

export const defaultNotificationSettings = {
  mode: UserSettingsNotificationsMode.All,
  silent: false,
  disableDmNotifications: false,
} as const

export const defaultPrivacySettings = {
  shareTimeZone: true,
  appearInGlobalSearch: true,
} as const

/** Upper bound for each privacy exception list. */
export const PRIVACY_RULE_MAX_TARGETS = 500

/** Who can see one piece of a user's information. The owner always can. */
export const PrivacyRuleSchema = z.object({
  audience: z.enum(["everyone", "nobody"]),
  /** User IDs that can see it when audience is nobody. */
  alwaysShare: z.array(z.number().int().positive()).max(PRIVACY_RULE_MAX_TARGETS).optional().default([]),
  /** User IDs that cannot see it when audience is everyone. */
  neverShare: z.array(z.number().int().positive()).max(PRIVACY_RULE_MAX_TARGETS).optional().default([]),
})

export type PrivacyRule = z.output<typeof PrivacyRuleSchema>
export type PrivacyRuleInput = z.input<typeof PrivacyRuleSchema>

export const defaultComposeSettings = {
  replacePastedLinksWithTitles: false,
} as const

const messageGestureAction = z.enum([
  "none", "toggleAck", "reply", "toggleHeart", "toggleThumbsUp", "reactionsMenu",
])

export const MessageGestureSettingsSchema = z.object({
  doubleTapAction: messageGestureAction.optional(),
  holdAction: messageGestureAction.optional(),
  swipeToReplyDirection: z.enum(["leftToRight", "rightToLeft"]).optional(),
})

export const UserSettingsGeneralSchema = z.object({
  messageGestures: MessageGestureSettingsSchema.optional(),
  /** Default notifications for all of your chats */
  notifications: z
    .object({
      /** Default mode for notifications */
      mode: z.enum(UserSettingsNotificationsMode).optional().default(defaultNotificationSettings.mode),

      /** If true, no sound will be played for notifications */
      silent: z.boolean().optional().default(defaultNotificationSettings.silent),

      /** If true, direct message notifications are disabled */
      disableDmNotifications: z.boolean().optional().default(defaultNotificationSettings.disableDmNotifications),
    })
    .optional()
    .default(defaultNotificationSettings),
  privacy: z
    .object({
      shareTimeZone: z.boolean().optional().default(defaultPrivacySettings.shareTimeZone),
      appearInGlobalSearch: z.boolean().optional().default(defaultPrivacySettings.appearInGlobalSearch),
      /** Authoritative once written; shareTimeZone mirrors it for older clients. */
      timeZone: PrivacyRuleSchema.optional(),
    })
    .optional()
    .default(defaultPrivacySettings),
  compose: z
    .object({
      replacePastedLinksWithTitles: z
        .boolean()
        .optional()
        .default(defaultComposeSettings.replacePastedLinksWithTitles),
    })
    .optional()
    .default(defaultComposeSettings),
})

export type UserSettingsGeneralInput = z.input<typeof UserSettingsGeneralSchema>
export type UserSettingsGeneral = z.output<typeof UserSettingsGeneralSchema>
