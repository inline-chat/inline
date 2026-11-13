import { describe, expect, it } from "vitest"
import { beginInlineQuietHandBack, isInlineQuietHandBack } from "./quiet-hand-backs"

describe("inline/quiet-hand-backs", () => {
  it("marks a chat only while a hand-back turn runs", () => {
    expect(isInlineQuietHandBack("qa-a", "12401")).toBe(false)
    const first = beginInlineQuietHandBack("qa-a", 12401n)
    const second = beginInlineQuietHandBack("qa-a", "12401")
    expect(isInlineQuietHandBack("qa-a", "12401")).toBe(true)
    expect(isInlineQuietHandBack("qa-b", "12401")).toBe(false)
    first()
    first()
    expect(isInlineQuietHandBack("qa-a", "12401")).toBe(true)
    second()
    expect(isInlineQuietHandBack("qa-a", "12401")).toBe(false)
  })
})
