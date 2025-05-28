import { z } from "zod/v4"

export enum UserSettingsNotificationsMode {
  All = "1",
  None = "2",
  Mentions = "3",
  ImportantOnly = "4",
}

export const UserSettingsGeneralSchema = z.object({
  /** Default notifications for all of your chats */
  notifications: z.object({
    /** Default mode for notifications */
    mode: z.enum(UserSettingsNotificationsMode),

    /** If true, no sound will be played for notifications */
    silent: z.boolean(),

    /** If true, the notification requires mentioning the user */
    zenModeRequiresMention: z.boolean().optional().default(true),

    /** If true, the default rules will be used */
    zenModeUsesDefaultRules: z.boolean().optional().default(true),

    /** Custom rules for notifications */
    zenModeCustomRules: z.string().optional().default(""),
  }),
})

export type UserSettingsGeneralInput = z.input<typeof UserSettingsGeneralSchema>
export type UserSettingsGeneral = z.output<typeof UserSettingsGeneralSchema>
