import { Effect, Layer } from "effect"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import {
  emailCampaignRecipients,
  emailSuppressions,
} from "@in/server/db/schema"
import {
  EmailUnsubscribeOperationFailure,
  EmailUnsubscribeOperations,
} from "./emailUnsubscribe.effect"

const attempt = <A>(run: () => PromiseLike<A>) =>
  Effect.tryPromise({
    try: run,
    catch: (cause) => new EmailUnsubscribeOperationFailure({ cause }),
  })

export const EmailUnsubscribeOperationsLive = Layer.succeed(
  EmailUnsubscribeOperations,
  {
    lookup: (tokenHash) =>
      attempt(async () => {
        const row = (await db
          .select({
            emailKey: emailCampaignRecipients.emailKey,
            emailEncrypted: emailCampaignRecipients.emailEncrypted,
          })
          .from(emailCampaignRecipients)
          .where(eq(emailCampaignRecipients.unsubscribeTokenHash, tokenHash))
          .limit(1))[0]
        return row ?? null
      }),
    suppress: (contact) =>
      attempt(async () => {
        await db
          .insert(emailSuppressions)
          .values({
            emailKey: contact.emailKey,
            emailEncrypted: contact.emailEncrypted,
            reason: "unsubscribe",
          })
          .onConflictDoNothing({ target: emailSuppressions.emailKey })
      }),
  },
)
