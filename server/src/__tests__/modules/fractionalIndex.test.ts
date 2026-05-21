import { describe, expect, test } from "bun:test"
import { FractionalIndex } from "@in/server/modules/fractionalIndex"

describe("FractionalIndex", () => {
  test("generates sorted append keys", () => {
    const keys = FractionalIndex.sequence(10)
    expect(keys).toEqual([...keys].sort())
  })

  test("generates keys between neighbors", () => {
    const left = FractionalIndex.after(null)
    const right = FractionalIndex.after(left)
    const middle = FractionalIndex.between(left, right)

    expect(left < middle).toBe(true)
    expect(middle < right).toBe(true)
  })

  test("supports prepending before existing keys", () => {
    const first = FractionalIndex.after(null)
    const before = FractionalIndex.before(first)

    expect(before < first).toBe(true)
  })

  test("validates persisted keys", () => {
    expect(FractionalIndex.isValid("0AZaz")).toBe(true)
    expect(FractionalIndex.isValid("")).toBe(false)
    expect(FractionalIndex.isValid("a-b")).toBe(false)
    expect(FractionalIndex.isValid("a".repeat(129))).toBe(false)
  })
})
