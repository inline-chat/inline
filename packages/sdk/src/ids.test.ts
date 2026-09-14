import { describe, expect, it } from "vitest"
import { asInlineId, InlineIdError } from "./ids.js"

describe("asInlineId", () => {
  it("accepts bigint", () => {
    expect(asInlineId(123n)).toBe(123n)
  })

  it("converts safe integers to bigint", () => {
    expect(asInlineId(42)).toBe(42n)
  })

  it("rejects non-safe integers", () => {
    expect(() => asInlineId(Number.MAX_SAFE_INTEGER + 1)).toThrow(InlineIdError)
  })

  it("rejects non-number non-bigint inputs", () => {
    // @ts-expect-error intentional misuse for runtime check
    expect(() => asInlineId("nope")).toThrow(InlineIdError)
  })
})
