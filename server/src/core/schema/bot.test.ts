import type {
  BotApiEnvelope as NeutralBotApiEnvelope,
  GetMeResult as NeutralGetMeResult,
} from "@inline-chat/bot-api-types"
import { describe, expect, it } from "@effect/vitest"
import { Effect, Exit, Schema } from "effect"
import { BotGetMeEnvelope, type BotGetMeResult, BotUser } from "./bot"

describe("Bot wire schemas", () => {
  it.effect("decodes getMe success without inventing omitted optional fields", () =>
    Effect.gen(function* () {
      const decoded = yield* Schema.decodeUnknownEffect(BotGetMeEnvelope)({
        ok: true,
        result: {
          user: {
            id: 42,
            is_bot: true,
            username: "inline_bot",
          },
        },
      })

      expect(decoded).toEqual({
        ok: true,
        result: {
          user: {
            id: 42,
            is_bot: true,
            username: "inline_bot",
          },
        },
      })

      const publicEnvelope: NeutralBotApiEnvelope<NeutralGetMeResult> = decoded
      expect(publicEnvelope.ok).toBe(true)
    }),
  )

  it.effect("decodes the compact public error envelope", () =>
    Effect.gen(function* () {
      const decoded = yield* Schema.decodeUnknownEffect(BotGetMeEnvelope)({
        ok: false,
        error_code: 401,
        description: "Unauthorized",
      })

      expect(decoded).toEqual({
        ok: false,
        error_code: 401,
        description: "Unauthorized",
      })
    }),
  )

  it.effect("encodes omitted optional Bot user fields as omitted", () =>
    Effect.gen(function* () {
      const encoded = yield* Schema.encodeEffect(BotUser)({
        id: 42,
        is_bot: true,
      })

      expect(encoded).toEqual({
        id: 42,
        is_bot: true,
      })
      expect("username" in encoded).toBe(false)
      expect("first_name" in encoded).toBe(false)
      expect("last_name" in encoded).toBe(false)
    }),
  )

  it.effect("strips excess properties at the Bot wire boundary", () =>
    Effect.gen(function* () {
      const decoded = yield* Schema.decodeUnknownEffect(BotUser)({
        id: 42,
        is_bot: true,
        internal_only: "must not cross the boundary",
      })

      expect(decoded).toEqual({
        id: 42,
        is_bot: true,
      })
      expect("internal_only" in decoded).toBe(false)
    }),
  )

  it.effect("rejects non-positive Bot API status codes", () =>
    Effect.gen(function* () {
      for (const errorCode of [0, -1]) {
        const exit = yield* Effect.exit(
          Schema.decodeUnknownEffect(BotGetMeEnvelope)({
            ok: false,
            error_code: errorCode,
            description: "Invalid status",
          }),
        )

        expect(Exit.isFailure(exit)).toBe(true)
      }
    }),
  )

  it.effect("rejects non-finite or unsafe Bot IDs", () =>
    Effect.gen(function* () {
      for (const id of [Number.NaN, Number.POSITIVE_INFINITY, Number.MAX_SAFE_INTEGER + 1]) {
        const exit = yield* Effect.exit(
          Schema.decodeUnknownEffect(BotUser)({
            id,
            is_bot: true,
          }),
        )

        expect(Exit.isFailure(exit)).toBe(true)
      }
    }),
  )

  it("keeps the inferred getMe result assignable to the neutral public package", () => {
    const schemaValue: BotGetMeResult = {
      user: {
        id: 1,
        is_bot: true,
      },
    }
    const publicValue: NeutralGetMeResult = schemaValue
    const roundTrip: BotGetMeResult = publicValue

    expect(roundTrip).toEqual(schemaValue)
  })
})
