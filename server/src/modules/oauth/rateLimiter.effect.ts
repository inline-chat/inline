import {
  Context,
  Effect,
  Layer,
} from "effect"
import {
  InMemoryRateLimiter,
  type InMemoryRateLimiterOptions,
} from "./rateLimiter"

export class OAuthRateLimiter extends Context.Service<
  OAuthRateLimiter,
  InMemoryRateLimiter
>()("@inline/server/oauth/OAuthRateLimiter") {}

export class InviteCodeRateLimiter extends Context.Service<
  InviteCodeRateLimiter,
  InMemoryRateLimiter
>()("@inline/server/auth/InviteCodeRateLimiter") {}

export const makeOAuthRateLimiterLayer = (
  options: InMemoryRateLimiterOptions = {},
): Layer.Layer<OAuthRateLimiter> =>
  Layer.effect(
    OAuthRateLimiter,
    Effect.acquireRelease(
      Effect.sync(() => new InMemoryRateLimiter(options)),
      (limiter) =>
        Effect.sync(() => {
          limiter.clear()
        }),
    ),
  )

export const makeInviteCodeRateLimiterLayer = (
  options: InMemoryRateLimiterOptions = {},
): Layer.Layer<InviteCodeRateLimiter> =>
  Layer.effect(
    InviteCodeRateLimiter,
    Effect.acquireRelease(
      Effect.sync(() => new InMemoryRateLimiter(options)),
      (limiter) =>
        Effect.sync(() => {
          limiter.clear()
        }),
    ),
  )
