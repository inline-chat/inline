import { describe, expect, it } from "@effect/vitest"
import { Effect, Exit, Schema } from "effect"
import {
  HttpStatusCode,
  InlineId,
  UnixSeconds,
  WireSafeInteger,
} from "./scalars"
import {
  SessionId,
  UserId,
} from "./identifiers"

describe("core scalar schemas", () => {
  it.effect("decodes valid values into distinct brands", () =>
    Effect.gen(function* () {
      const id = yield* Schema.decodeUnknownEffect(InlineId)(42)
      const timestamp = yield* Schema.decodeUnknownEffect(UnixSeconds)(1_725_000_000)

      expect(id).toBe(42)
      expect(timestamp).toBe(1_725_000_000)

      const acceptsInlineId = (_value: InlineId): void => {}
      const acceptsUnixSeconds = (_value: UnixSeconds): void => {}
      acceptsInlineId(id)
      acceptsUnixSeconds(timestamp)
    }),
  )

  it.effect("rejects unsafe, fractional, and non-finite wire integers", () =>
    Effect.gen(function* () {
      const values = [Number.MAX_SAFE_INTEGER + 1, 1.5, Number.NaN, Number.POSITIVE_INFINITY]

      for (const value of values) {
        const exit = yield* Effect.exit(Schema.decodeUnknownEffect(WireSafeInteger)(value))
        expect(Exit.isFailure(exit)).toBe(true)
      }
    }),
  )

  it.effect("rejects zero and negative Inline identifiers", () =>
    Effect.gen(function* () {
      for (const value of [0, -1]) {
        const exit = yield* Effect.exit(Schema.decodeUnknownEffect(InlineId)(value))
        expect(Exit.isFailure(exit)).toBe(true)
      }
    }),
  )

  it.effect("decodes domain identifiers at their trust boundary", () =>
    Effect.gen(function* () {
      const userId = yield* Schema.decodeUnknownEffect(UserId)(42)
      const sessionId = yield* Schema.decodeUnknownEffect(SessionId)(7)

      expect(userId).toBe(42)
      expect(sessionId).toBe(7)
    }),
  )

  it.effect("bounds HTTP status codes", () =>
    Effect.gen(function* () {
      expect(
        yield* Schema.decodeUnknownEffect(HttpStatusCode)(420),
      ).toBe(420)

      for (const value of [99, 600, 400.5]) {
        const exit = yield* Effect.exit(
          Schema.decodeUnknownEffect(HttpStatusCode)(value),
        )
        expect(Exit.isFailure(exit)).toBe(true)
      }
    }),
  )
})
