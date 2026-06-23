import { describe, expect, it } from "vitest"
import { asInlineUnixSeconds, InlineUnixSecondsError } from "./time.js"

describe("asInlineUnixSeconds", () => {
  it("accepts bigint", () => {
    expect(asInlineUnixSeconds(123n)).toBe(123n)
  })

  it("converts safe integers to bigint", () => {
    expect(asInlineUnixSeconds(42)).toBe(42n)
  })

  it("rejects non-safe integers", () => {
    expect(() => asInlineUnixSeconds(Number.MAX_SAFE_INTEGER + 1)).toThrow(InlineUnixSecondsError)
  })

  it("rejects non-number non-bigint inputs", () => {
    // @ts-expect-error intentional misuse for runtime check
    expect(() => asInlineUnixSeconds("nope")).toThrow(InlineUnixSecondsError)
  })
})

