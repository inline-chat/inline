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

export const UserSettingsGeneralSchema = z.object({
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
})

export type UserSettingsGeneralInput = z.input<typeof UserSettingsGeneralSchema>
export type UserSettingsGeneral = z.output<typeof UserSettingsGeneralSchema>
