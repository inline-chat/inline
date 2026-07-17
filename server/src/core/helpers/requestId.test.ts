import { describe, expect, it } from "@effect/vitest"
import { Option } from "effect"
import {
  generateRequestId,
  MAX_REQUEST_ID_LENGTH,
  parseRequestId,
  RequestId,
  resolveRequestId,
} from "./requestId"

describe("request IDs", () => {
  it("accepts and trims the current public request-ID grammar", () => {
    const parsed = parseRequestId("  req.ABC_123-test  ")

    expect(Option.getOrUndefined(parsed)).toBe("req.ABC_123-test")
  })

  it("rejects empty, oversized, and unsafe header values", () => {
    const invalid = ["", "   ", "contains spaces", "contains/slash", "a".repeat(MAX_REQUEST_ID_LENGTH + 1)]

    for (const value of invalid) {
      expect(Option.isNone(parseRequestId(value))).toBe(true)
    }
  })

  it("uses a valid incoming value without invoking the fallback", () => {
    let generated = 0
    const value = resolveRequestId(" request-42 ", () => {
      generated += 1
      return RequestId.make("generated")
    })

    expect(value).toBe("request-42")
    expect(generated).toBe(0)
  })

  it("generates a branded fallback for absent or invalid values", () => {
    const fallback = RequestId.make("generated-42")

    expect(resolveRequestId(null, () => fallback)).toBe(fallback)
    expect(resolveRequestId("not valid", () => fallback)).toBe(fallback)
    expect(generateRequestId(() => "deterministic-id")).toBe("deterministic-id")
  })
})
