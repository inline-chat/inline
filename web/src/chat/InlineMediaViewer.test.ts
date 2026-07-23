import { describe, expect, it } from "vitest"
import { containedInlineMediaRect } from "./InlineMediaViewerGeometry"

describe("containedInlineMediaRect", () => {
  it("centers large media inside the exact viewport inset", () => {
    expect(containedInlineMediaRect(2_000, 1_000, 1_000, 700)).toEqual({
      left: 32,
      top: 116,
      width: 936,
      height: 468,
    })
  })

  it("does not upscale small media", () => {
    expect(containedInlineMediaRect(320, 200, 1_000, 700)).toEqual({
      left: 340,
      top: 250,
      width: 320,
      height: 200,
    })
  })
})
