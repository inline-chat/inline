import { describe, expect, test } from "bun:test"
import { Exit, Redacted, Schema } from "effect"
import { INT64_MAX, REQUEST_ID_MAX_LENGTH } from "../constants"
import {
  BearerToken,
  ChatId,
  MessageGlobalId,
  PositiveInt,
  RequestId,
  SpaceId,
  TimestampSeconds,
  UserId,
} from "./index"

const decodes = <S extends Schema.ConstraintDecoder<unknown>>(schema: S, input: unknown): boolean =>
  Exit.isSuccess(Schema.decodeUnknownExit(schema)(input))

describe("Effect server leaf primitives", () => {
  test("positive integers are finite, safe, whole, and greater than zero", () => {
    expect(decodes(PositiveInt, 1)).toBe(true)
    expect(decodes(PositiveInt, Number.MAX_SAFE_INTEGER)).toBe(true)
    expect(decodes(PositiveInt, 0)).toBe(false)
    expect(decodes(PositiveInt, 1.5)).toBe(false)
    expect(decodes(PositiveInt, Number.MAX_SAFE_INTEGER + 1)).toBe(false)
    expect(decodes(PositiveInt, Number.POSITIVE_INFINITY)).toBe(false)
  })

  test("domain IDs share validation but keep distinct brands", () => {
    const userId = Schema.decodeUnknownSync(UserId)(42)
    const spaceId = Schema.decodeUnknownSync(SpaceId)(42)
    const chatId = Schema.decodeUnknownSync(ChatId)(42)
    const acceptsUserId = (id: UserId): UserId => id

    expect(Number(userId)).toBe(42)
    expect(Number(spaceId)).toBe(42)
    expect(Number(chatId)).toBe(42)
    expect(acceptsUserId(userId)).toBe(userId)

    // @ts-expect-error A SpaceId must not cross a UserId boundary without an explicit adapter.
    acceptsUserId(spaceId)
  })

  test("number-backed entity IDs match PostgreSQL integer bounds", () => {
    expect(decodes(UserId, 2_147_483_647)).toBe(true)
    expect(decodes(UserId, 2_147_483_648)).toBe(false)
  })

  test("int64-backed IDs preserve the full signed database range", () => {
    expect(decodes(MessageGlobalId, 1n)).toBe(true)
    expect(decodes(MessageGlobalId, INT64_MAX)).toBe(true)
    expect(decodes(MessageGlobalId, 0n)).toBe(false)
    expect(decodes(MessageGlobalId, INT64_MAX + 1n)).toBe(false)
    expect(decodes(MessageGlobalId, 1)).toBe(false)
  })

  test("seconds timestamps reject millisecond-scale values", () => {
    expect(decodes(TimestampSeconds, 0)).toBe(true)
    expect(decodes(TimestampSeconds, 1_700_000_000)).toBe(true)
    expect(decodes(TimestampSeconds, 1_700_000_000_000)).toBe(false)
    expect(decodes(TimestampSeconds, -1)).toBe(false)
    expect(decodes(TimestampSeconds, 1.25)).toBe(false)
  })

  test("request IDs preserve the current header contract", () => {
    expect(decodes(RequestId, "request_01.test-value")).toBe(true)
    expect(decodes(RequestId, " with-space ")).toBe(false)
    expect(decodes(RequestId, "x".repeat(REQUEST_ID_MAX_LENGTH))).toBe(true)
    expect(decodes(RequestId, "x".repeat(REQUEST_ID_MAX_LENGTH + 1))).toBe(false)
  })

  test("bearer credentials decode from strings and remain redacted", () => {
    const token = Schema.decodeUnknownSync(BearerToken)("123:secret-token")
    let encodeFailure = ""

    try {
      Schema.encodeSync(BearerToken)(token)
    } catch (error) {
      encodeFailure = String(error)
    }

    expect(String(Redacted.value(token))).toBe("123:secret-token")
    expect(String(token)).not.toContain("secret-token")
    expect(encodeFailure).toContain("Cannot encode Redacted")
    expect(encodeFailure).not.toContain("secret-token")
    expect(decodes(BearerToken, "")).toBe(false)
    expect(decodes(BearerToken, " padded ")).toBe(false)
  })
})
