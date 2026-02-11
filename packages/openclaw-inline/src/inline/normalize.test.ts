import { describe, expect, it } from "vitest"
import { looksLikeInlineTargetId, normalizeInlineTarget } from "./normalize"

describe("inline/normalize", () => {
  it("normalizes inline and chat prefixes", () => {
    expect(normalizeInlineTarget("inline:chat:7")).toBe("7")
    expect(normalizeInlineTarget("chat:7")).toBe("7")
    expect(normalizeInlineTarget(" 7 ")).toBe("7")
  })

  it("returns undefined for empty targets", () => {
    expect(normalizeInlineTarget("")).toBeUndefined()
    expect(normalizeInlineTarget("   ")).toBeUndefined()
  })

  it("detects id-like targets", () => {
    expect(looksLikeInlineTargetId("7")).toBe(true)
    expect(looksLikeInlineTargetId("chat:7")).toBe(true)
    expect(looksLikeInlineTargetId("nope")).toBe(false)
  })
})

