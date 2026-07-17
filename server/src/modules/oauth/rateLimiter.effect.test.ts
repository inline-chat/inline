import { describe, expect, it } from "@effect/vitest"
import { Effect } from "effect"
import {
  InMemoryRateLimiter,
} from "./rateLimiter"
import {
  InviteCodeRateLimiter,
  OAuthRateLimiter,
  makeInviteCodeRateLimiterLayer,
  makeOAuthRateLimiterLayer,
} from "./rateLimiter.effect"

const rule = {
  max: 1,
  windowMs: 1_000,
} as const

describe("auth rate limiter ownership", () => {
  it("bounds storage with deterministic least-recently-used eviction", () => {
    const limiter = new InMemoryRateLimiter({
      capacity: 2,
    })

    limiter.consume({ key: "oldest", nowMs: 0, rule })
    limiter.consume({ key: "recent", nowMs: 0, rule })
    limiter.consume({ key: "oldest", nowMs: 1, rule })
    limiter.consume({ key: "new", nowMs: 1, rule })

    expect(limiter.size).toBe(2)
    expect(
      limiter.consume({
        key: "recent",
        nowMs: 2,
        rule,
      }),
    ).toMatchObject({ allowed: true })
  })

  it("expires a bucket lazily without scanning unrelated keys", () => {
    const limiter = new InMemoryRateLimiter()

    expect(
      limiter.consume({ key: "client", nowMs: 0, rule }),
    ).toMatchObject({ allowed: true })
    expect(
      limiter.consume({
        key: "client",
        nowMs: 999,
        rule,
      }),
    ).toMatchObject({ allowed: false })
    expect(
      limiter.consume({
        key: "client",
        nowMs: 1_000,
        rule,
      }),
    ).toMatchObject({ allowed: true })
  })

  it("consumes a shared bucket atomically across concurrent callers", async () => {
    const limiter = new InMemoryRateLimiter()
    const results = await Promise.all(
      Array.from({ length: 20 }, () =>
        Promise.resolve().then(() =>
          limiter.consume({
            key: "shared",
            nowMs: 0,
            rule: {
              max: 5,
              windowMs: 1_000,
            },
          }),
        ),
      ),
    )

    expect(
      results.filter((result) => result.allowed),
    ).toHaveLength(5)
  })

  it("clears storage on Layer disposal and starts fresh per Layer instance", async () => {
    let released:
      | InMemoryRateLimiter
      | undefined

    const runOnce = () =>
      Effect.runPromise(
        OAuthRateLimiter.use((limiter) =>
          Effect.sync(() => {
            released = limiter
            const first = limiter.consume({
              key: "client",
              nowMs: 0,
              rule,
            })
            const second = limiter.consume({
              key: "client",
              nowMs: 0,
              rule,
            })
            return [first.allowed, second.allowed] as const
          }),
        ).pipe(
          Effect.provide(
            makeOAuthRateLimiterLayer(),
          ),
        ),
      )

    expect(await runOnce()).toEqual([true, false])
    expect(released?.size).toBe(0)
    expect(await runOnce()).toEqual([true, false])
    expect(released?.size).toBe(0)
  })

  it("isolates OAuth and invite buckets within the same process", async () => {
    const result = await Effect.runPromise(
      Effect.gen(function* () {
        const oauth = yield* OAuthRateLimiter
        const invite = yield* InviteCodeRateLimiter

        return {
          oauth: oauth.consume({
            key: "shared-key",
            nowMs: 0,
            rule,
          }),
          invite: invite.consume({
            key: "shared-key",
            nowMs: 0,
            rule,
          }),
        }
      }).pipe(
        Effect.provide(
          makeOAuthRateLimiterLayer(),
        ),
        Effect.provide(
          makeInviteCodeRateLimiterLayer(),
        ),
      ),
    )

    expect(result.oauth.allowed).toBe(true)
    expect(result.invite.allowed).toBe(true)
  })
})
