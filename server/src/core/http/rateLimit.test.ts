import { describe, expect, it } from "@effect/vitest"
import { Effect } from "effect"
import {
  DEFAULT_HTTP_RATE_LIMIT_MAX,
  HttpRateLimitExceeded,
  HttpRateLimiter,
  makeHttpRateLimiterLayer,
  parseHttpRateLimitMax,
} from "./rateLimit"

describe("HttpRateLimiter", () => {
  it.effect("keeps rejection typed and resets at the fixed-window boundary", () => {
    let now = 10_000

    return Effect.gen(function* () {
      const limiter = yield* HttpRateLimiter
      const first = yield* limiter.consume("client")
      const exceeded = yield* Effect.flip(limiter.consume("client"))

      expect(first).toEqual({
        limit: 1,
        remaining: 0,
        resetSeconds: 1,
      })
      expect(exceeded).toBeInstanceOf(HttpRateLimitExceeded)
      expect(exceeded).toMatchObject({
        limit: 1,
        remaining: 0,
        resetSeconds: 1,
      })

      yield* limiter.consume("refundable")
      yield* limiter.refund("refundable")
      expect(yield* limiter.consume("refundable")).toEqual(first)

      now = 11_000
      expect(yield* limiter.consume("client")).toEqual(first)
    }).pipe(
      Effect.provide(
        makeHttpRateLimiterLayer({
          max: 1,
          nowMillis: () => now,
          windowMillis: 1_000,
        }),
      ),
    )
  })

  it.effect("evicts the least-recently-used key at the configured bound", () =>
    Effect.gen(function* () {
      const limiter = yield* HttpRateLimiter

      yield* limiter.consume("oldest")
      yield* limiter.consume("second")
      yield* limiter.consume("newest")

      // "oldest" was evicted when "newest" entered a two-key store, so this
      // is a fresh permit rather than a second request in the same window.
      expect(yield* limiter.consume("oldest")).toMatchObject({
        limit: 1,
        remaining: 0,
      })
    }).pipe(
      Effect.provide(
        makeHttpRateLimiterLayer({
          capacity: 2,
          max: 1,
          nowMillis: () => 0,
        }),
      ),
    ),
  )

  it("sanitizes the environment-compatible request limit", () => {
    expect(parseHttpRateLimitMax(undefined)).toBe(
      DEFAULT_HTTP_RATE_LIMIT_MAX,
    )
    expect(parseHttpRateLimitMax("500")).toBe(500)
    expect(parseHttpRateLimitMax("2.9")).toBe(2)
    expect(parseHttpRateLimitMax("0")).toBe(
      DEFAULT_HTTP_RATE_LIMIT_MAX,
    )
    expect(parseHttpRateLimitMax("10001")).toBe(
      DEFAULT_HTTP_RATE_LIMIT_MAX,
    )
    expect(parseHttpRateLimitMax("not-a-number")).toBe(
      DEFAULT_HTTP_RATE_LIMIT_MAX,
    )
  })
})
