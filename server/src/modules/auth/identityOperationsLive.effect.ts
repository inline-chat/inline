import {
  Effect,
  Layer,
} from "effect"
import {
  handler as sendSmsCodeHandler,
} from "@in/server/methods/sendSmsCode"
import {
  handler as verifySmsCodeHandler,
} from "@in/server/methods/verifySmsCode"
import {
  handler as sendEmailCodeHandler,
} from "@in/server/methods/sendEmailCode"
import {
  handler as verifyEmailCodeHandler,
} from "@in/server/methods/verifyEmailCode"
import {
  makeCheckInviteCodeHandler,
} from "@in/server/methods/checkInviteCode"
import {
  handler as logoutHandler,
} from "@in/server/methods/logout"
import {
  IdentityOperations,
} from "./identityOperations.effect"
import {
  makeIdentityOperations,
} from "./identityOperationsAdapter.effect"
import {
  InviteCodeRateLimiter,
  makeInviteCodeRateLimiterLayer,
} from "../oauth/rateLimiter.effect"

export const IdentityOperationsLive = Layer.effect(
  IdentityOperations,
  InviteCodeRateLimiter.use((inviteLimiter) =>
    Effect.succeed(
      makeIdentityOperations({
        sendSmsCode: (input, context) =>
          sendSmsCodeHandler({ ...input }, context),
        verifySmsCode: (input, context) =>
          verifySmsCodeHandler({ ...input }, context),
        sendEmailCode: (input, context) =>
          sendEmailCodeHandler({ ...input }, context),
        verifyEmailCode: (input, context) =>
          verifyEmailCodeHandler({ ...input }, context),
        checkInviteCode: makeCheckInviteCodeHandler(
          inviteLimiter,
        ),
        logout: (context) => logoutHandler({}, context),
      }),
    ),
  ),
).pipe(
  Layer.provide(makeInviteCodeRateLimiterLayer()),
)
