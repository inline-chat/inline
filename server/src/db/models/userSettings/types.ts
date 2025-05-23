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
  }),
})

export type UserSettingsGeneralInput = z.input<typeof UserSettingsGeneralSchema>
export type UserSettingsGeneral = z.output<typeof UserSettingsGeneralSchema>
