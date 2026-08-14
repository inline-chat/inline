import {
  Effect,
} from "effect"
import {
  TRANSACTIONAL_EMAIL_FROM_ADDRESS,
  transactionalEmailReplyTo,
  type TransactionalEmailSender,
} from "@in/server/modules/email/transactionalIdentity"
import {
  Log,
} from "@in/server/utils/log"
import {
  AdminOperationFailure,
  type AdminOperationsShape,
} from "./adminOperations.effect"

const sendWithConfiguredProvider: TransactionalEmailSender = async (input) => {
  const { sendTransactionalEmailWithProvider } = await import("@in/server/utils/email")
  return sendTransactionalEmailWithProvider(input)
}

export const makeTestEmailProviderOperation = (
  sendProviderEmail: TransactionalEmailSender = sendWithConfiguredProvider,
): AdminOperationsShape["testEmailProvider"] =>
  (input, session) =>
    Effect.gen(function* () {
      const providerLabel = input.provider === "ses" ? "Amazon SES" : "Resend"
      const result = yield* Effect.tryPromise({
        try: () =>
          sendProviderEmail({
            provider: input.provider,
            to: session.email,
            content: {
              subject: `[TEST] Inline ${providerLabel} delivery`,
              text: [
                `This confirms that Inline can deliver transactional email through ${providerLabel}.`,
                `Sender: Inline <${TRANSACTIONAL_EMAIL_FROM_ADDRESS}>`,
                "The active email provider setting was not changed.",
              ].join("\n\n"),
              html: [
                `<p>This confirms that Inline can deliver transactional email through <strong>${providerLabel}</strong>.</p>`,
                `<p>Sender: Inline &lt;${TRANSACTIONAL_EMAIL_FROM_ADDRESS}&gt;</p>`,
                "<p>The active email provider setting was not changed.</p>",
              ].join(""),
            },
          }),
        catch: (cause) =>
          new AdminOperationFailure({
            operation: "admin.email-provider-test.deliver",
            cause,
          }),
      })
      const sentAt = new Date().toISOString()
      Log.shared.info("Admin email provider test accepted", {
        provider: input.provider,
        userId: session.userId,
      })
      return {
        kind: "json" as const,
        body: {
          ok: true as const,
          provider: input.provider,
          recipient: session.email,
          fromAddress: TRANSACTIONAL_EMAIL_FROM_ADDRESS,
          replyToAddress: transactionalEmailReplyTo(input.provider),
          messageId: result.messageId,
          sentAt,
        },
      }
    })
