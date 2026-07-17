import {
  Effect,
} from "effect"
import type {
  verifyEmailLoginChallenge,
} from "@in/server/modules/auth/emailLoginChallenges"
import {
  AdminOperationFailure,
  AdminRejected,
} from "./adminOperations.effect"

export type AdminEmailChallengeVerifier = (
  input: Parameters<
    typeof verifyEmailLoginChallenge
  >[0],
) => PromiseLike<boolean>

/**
 * Intentional correctness fix over the legacy catch-all: a rejected code is a
 * public 401, while an unavailable verifier is an operational 500 reported at
 * the transport boundary. Treating an outage as a wrong code hides incidents
 * and encourages clients to retry credentials that were never evaluated.
 */
export const verifyAdminEmailChallenge = (
  input: Parameters<
    typeof verifyEmailLoginChallenge
  >[0],
  verifier: AdminEmailChallengeVerifier,
) =>
  Effect.tryPromise({
    try: () => verifier(input),
    catch: (cause) =>
      new AdminOperationFailure({
        operation:
          "admin.auth.verify-email-code.verify",
        cause,
      }),
  }).pipe(
    Effect.flatMap((verified) =>
      verified
        ? Effect.void
        : Effect.fail(
            new AdminRejected({
              status: 401,
              error: "invalid_code",
            }),
          ),
    ),
  )
