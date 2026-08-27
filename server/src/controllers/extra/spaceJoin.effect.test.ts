import { describe, expect, it } from "@effect/vitest"
import { Effect } from "effect"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import {
  SpaceJoinRateLimitExceeded,
  makeSpaceJoinOperations,
} from "./spaceJoin.effect"

describe("space join resolver rate limits", () => {
  it.effect("limits private token resolution to 20 attempts per minute per IP", () =>
    Effect.gen(function* () {
      let calls = 0
      const operations = makeSpaceJoinOperations({
        limiter: new InMemoryRateLimiter(),
        nowMs: () => 1_000,
        resolve: async () => {
          calls += 1
          return null
        },
      })
      for (let index = 0; index < 20; index += 1) {
        yield* operations.consumeRequest("203.0.113.7")
        yield* operations.resolve(
          { kind: "invite_token", value: `iv1_${index}` },
          "203.0.113.7",
        )
      }
      const failure = yield* Effect.flip(operations.resolve(
        { kind: "invite_token", value: "iv1_denied" },
        "203.0.113.7",
      ))
      expect(failure).toBeInstanceOf(SpaceJoinRateLimitExceeded)
      if (!(failure instanceof SpaceJoinRateLimitExceeded)) return
      expect(failure.retryAfterSeconds).toBe(60)
      expect(calls).toBe(20)
    }))

  it.effect("limits all resolution to 60 attempts per minute per IP", () =>
    Effect.gen(function* () {
      const operations = makeSpaceJoinOperations({
        limiter: new InMemoryRateLimiter(),
        nowMs: () => 5_000,
        resolve: async () => null,
      })
      for (let index = 0; index < 60; index += 1) {
        yield* operations.consumeRequest("198.51.100.9")
      }
      const failure = yield* Effect.flip(
        operations.consumeRequest("198.51.100.9"),
      )
      expect(failure).toBeInstanceOf(SpaceJoinRateLimitExceeded)
      if (!(failure instanceof SpaceJoinRateLimitExceeded)) return
      expect(failure.retryAfterSeconds).toBe(60)
    }))

  it.effect("caps one reference across rotating client IPs", () =>
    Effect.gen(function* () {
      const operations = makeSpaceJoinOperations({
        limiter: new InMemoryRateLimiter(),
        nowMs: () => 9_000,
        resolve: async () => null,
      })
      for (let index = 0; index < 120; index += 1) {
        yield* operations.consumeRequest(`198.51.100.${index}`)
        yield* operations.resolve(
          { kind: "public_handle", value: "TownHall" },
          `198.51.100.${index}`,
        )
      }
      const failure = yield* Effect.flip(operations.resolve(
        { kind: "public_handle", value: "townhall" },
        "203.0.113.200",
      ))
      expect(failure).toBeInstanceOf(SpaceJoinRateLimitExceeded)
      if (!(failure instanceof SpaceJoinRateLimitExceeded)) return
      expect(failure.retryAfterSeconds).toBe(600)
    }))
})
