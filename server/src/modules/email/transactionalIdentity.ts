export type TransactionalEmailProvider = "ses" | "resend"

export const TRANSACTIONAL_EMAIL_FROM_ADDRESS = "team@inline.chat" as const
export const SES_TRANSACTIONAL_REPLY_TO_ADDRESS = "hi@inline.chat" as const
export const RESEND_TRANSACTIONAL_REPLY_TO_ADDRESS = "founders@inline.chat" as const

export const transactionalEmailReplyTo = (
  provider: TransactionalEmailProvider,
): typeof SES_TRANSACTIONAL_REPLY_TO_ADDRESS | typeof RESEND_TRANSACTIONAL_REPLY_TO_ADDRESS =>
  provider === "ses"
    ? SES_TRANSACTIONAL_REPLY_TO_ADDRESS
    : RESEND_TRANSACTIONAL_REPLY_TO_ADDRESS

export type TransactionalEmailSender = (input: {
  readonly provider: TransactionalEmailProvider
  readonly to: string
  readonly content: {
    readonly subject: string
    readonly text: string
    readonly html?: string | undefined
  }
}) => Promise<{ readonly messageId: string | null }>
