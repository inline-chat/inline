import { describe, expect, test } from "vitest"
import { computePosition } from "./position"

const viewport = { x: 0, y: 0, width: 1000, height: 800 }
const floating = { width: 200, height: 300 }

describe("computePosition", () => {
  test("bottom-start aligns to the anchor's start edge", () => {
    const result = computePosition({
      anchor: { x: 100, y: 100, width: 80, height: 30 },
      floating,
      boundary: viewport,
      placement: "bottom-start",
      offset: 4,
    })
    expect(result).toMatchObject({ x: 100, y: 134, side: "bottom", align: "start" })
    expect(result.maxHeight).toBe(800 - 134)
  })

  test("start and end alignment follow the writing direction", () => {
    const anchor = { x: 500, y: 100, width: 80, height: 30 }
    const rtl = computePosition({ anchor, floating, boundary: viewport, placement: "bottom-start", dir: "rtl" })
    expect(rtl.x).toBe(580 - 200)
    expect(rtl.align).toBe("end")
  })

  test("inline sides resolve by direction", () => {
    const anchor = { x: 400, y: 100, width: 100, height: 24 }
    expect(computePosition({ anchor, floating, boundary: viewport, placement: "inline-end-start" })).toMatchObject({
      side: "right",
      x: 500,
      y: 100,
    })
    expect(
      computePosition({ anchor, floating, boundary: viewport, placement: "inline-end-start", dir: "rtl" }),
    ).toMatchObject({ side: "left", x: 200, y: 100 })
  })

  test("flips to the opposite side when the preferred side overflows", () => {
    const result = computePosition({
      anchor: { x: 100, y: 700, width: 80, height: 30 },
      floating,
      boundary: viewport,
      placement: "bottom-start",
      offset: 4,
    })
    expect(result.side).toBe("top")
    expect(result.y).toBe(700 - 4 - 300)
  })

  test("a submenu flips from inline-end to inline-start at the window edge", () => {
    const result = computePosition({
      anchor: { x: 700, y: 100, width: 200, height: 24 },
      floating,
      boundary: viewport,
      placement: "inline-end-start",
    })
    expect(result.side).toBe("left")
    expect(result.x).toBe(500)
  })

  test("does not flip when the opposite side has even less room", () => {
    const result = computePosition({
      anchor: { x: 100, y: 450, width: 80, height: 30 },
      floating: { width: 200, height: 500 },
      boundary: viewport,
      placement: "bottom",
    })
    expect(result.side).toBe("top")
    const stays = computePosition({
      anchor: { x: 100, y: 300, width: 80, height: 30 },
      floating: { width: 200, height: 500 },
      boundary: viewport,
      placement: "bottom",
    })
    expect(stays.side).toBe("bottom")
    expect(stays.maxHeight).toBe(800 - 330)
  })

  test("shifts along the cross axis to stay inside the padded boundary", () => {
    const result = computePosition({
      anchor: { x: 900, y: 100, width: 80, height: 30 },
      floating,
      boundary: viewport,
      placement: "bottom-start",
      padding: 8,
    })
    expect(result.x).toBe(1000 - 8 - 200)
  })

  test("flipAlign opens a context menu leftward of the point near the right edge", () => {
    const result = computePosition({
      anchor: { x: 900, y: 100, width: 0, height: 0 },
      floating,
      boundary: viewport,
      placement: "bottom-start",
      flipAlign: true,
    })
    expect(result.x).toBe(700)
    expect(result.align).toBe("end")
  })

  test("size limits a top-placed layer to the room above, keeping it touching the anchor", () => {
    const result = computePosition({
      anchor: { x: 100, y: 200, width: 80, height: 30 },
      floating: { width: 200, height: 900 },
      boundary: viewport,
      placement: "top",
      flip: false,
      padding: 10,
    })
    expect(result.maxHeight).toBe(190)
    expect(result.y).toBe(10)
  })

  test("the arrow points at the anchor center and stays inside the layer", () => {
    const centered = computePosition({
      anchor: { x: 100, y: 100, width: 40, height: 20 },
      floating: { width: 200, height: 100 },
      boundary: viewport,
      placement: "bottom-start",
      arrow: { size: 10, padding: 6 },
    })
    expect(centered.arrow).toEqual({ x: 15 })
    const clamped = computePosition({
      anchor: { x: 0, y: 100, width: 4, height: 20 },
      floating: { width: 200, height: 100 },
      boundary: viewport,
      placement: "bottom-start",
      arrow: { size: 10, padding: 6 },
    })
    expect(clamped.arrow).toEqual({ x: 6 })
  })

  test("center alignment and a right side arrow on the y axis", () => {
    const result = computePosition({
      anchor: { x: 100, y: 300, width: 40, height: 40 },
      floating: { width: 100, height: 100 },
      boundary: viewport,
      placement: "right",
      offset: 6,
      arrow: { size: 8 },
    })
    expect(result).toMatchObject({ x: 146, y: 270, side: "right", align: "center", arrow: { y: 46 } })
  })
})
