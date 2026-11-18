import type { RowKey } from "@inline/core-protocol"
import { describe, expect, it } from "vitest"
import {
  contentHeight,
  firstIndexBelow,
  LIST_PADDING,
  lowerBound,
  rowMetrics,
  rowTop,
  scrollToReveal,
  unreadBelow,
  unreadScrollPlan,
  visibleRange,
  windowKeys,
} from "./geometry"

const keys = (n: number) => Array.from({ length: n }, (_, i) => `dialog:${i}` as RowKey)

describe("row metrics", () => {
  it("match the Mac item sizes", () => {
    expect(rowMetrics("compact")).toEqual({ rowHeight: 30, avatarSize: 22, showsPreview: false })
    expect(rowMetrics("standard")).toEqual({ rowHeight: 40, avatarSize: 30, showsPreview: true })
  })

  it("lay rows out at fixed offsets after the padding", () => {
    expect(rowTop(0, 40)).toBe(LIST_PADDING)
    expect(rowTop(10, 40)).toBe(LIST_PADDING + 400)
    expect(contentHeight(0, 40)).toBe(0)
    expect(contentHeight(5000, 40)).toBe(5000 * 40 + 2 * LIST_PADDING)
  })
})

describe("visibleRange", () => {
  it("covers the viewport plus overscan, clamped to the list", () => {
    expect(visibleRange({ scrollTop: 0, height: 400 }, 5000, 40, 8)).toEqual({ first: 0, last: 18 })
    // Scrolled to row 100: rows 100..109 visible, 8 more each side.
    const top = rowTop(100, 40)
    expect(visibleRange({ scrollTop: top, height: 400 }, 5000, 40, 8)).toEqual({ first: 92, last: 118 })
    expect(visibleRange({ scrollTop: 1e9, height: 400 }, 50, 40, 8)).toEqual({ first: 50, last: 50 })
    expect(visibleRange({ scrollTop: 0, height: 400 }, 0, 40)).toEqual({ first: 0, last: 0 })
  })

  it("stays bounded for any list length", () => {
    const range = visibleRange({ scrollTop: 123_456, height: 900 }, 1_000_000, 30, 8)
    expect(range.last - range.first).toBeLessThanOrEqual(Math.ceil(900 / 30) + 1 + 16)
  })
})

describe("windowKeys", () => {
  const list = keys(100)

  it("is the range when the extra row is inside it", () => {
    expect(windowKeys(list, { first: 10, last: 13 }, 11)).toEqual(["dialog:10", "dialog:11", "dialog:12"])
  })

  it("adds the extra row in list order", () => {
    expect(windowKeys(list, { first: 10, last: 12 }, 2)).toEqual(["dialog:2", "dialog:10", "dialog:11"])
    expect(windowKeys(list, { first: 10, last: 12 }, 90)).toEqual(["dialog:10", "dialog:11", "dialog:90"])
    expect(windowKeys(list, { first: 10, last: 12 }, 500)).toEqual(["dialog:10", "dialog:11"])
  })
})

describe("scrollToReveal", () => {
  const viewport = { scrollTop: rowTop(20, 40), height: 400 }

  it("leaves a fully visible row alone", () => {
    expect(scrollToReveal(22, viewport, 100, 40)).toBeUndefined()
  })

  it("scrolls up to a row above, with the padding as margin", () => {
    expect(scrollToReveal(5, viewport, 100, 40)).toBe(rowTop(5, 40) - LIST_PADDING)
    expect(scrollToReveal(0, viewport, 100, 40)).toBe(0)
  })

  it("scrolls down just enough for a row below, clamped to the end", () => {
    expect(scrollToReveal(40, viewport, 100, 40)).toBe(rowTop(41, 40) + LIST_PADDING - 400)
    expect(scrollToReveal(99, viewport, 100, 40)).toBe(contentHeight(100, 40) - 400)
  })
})

describe("unread below", () => {
  it("finds the first row below the bottom edge; a cut row counts as visible", () => {
    expect(firstIndexBelow({ scrollTop: 0, height: 406 }, 40)).toBe(10)
    expect(firstIndexBelow({ scrollTop: 0, height: 407 }, 40)).toBe(11)
  })

  it("counts prominent unread rows below and targets the nearest", () => {
    expect(lowerBound([1, 4, 9, 20], 5)).toBe(2)
    expect(unreadBelow([1, 4, 9, 20], 5)).toEqual({ count: 2, target: 9 })
    expect(unreadBelow([1, 4], 5)).toEqual({ count: 0 })
    expect(unreadBelow([], 0)).toEqual({ count: 0 })
  })

  it("centers the target, jumping first when it is more than a viewport away (Mac plan)", () => {
    const near = unreadScrollPlan({ currentOffset: 0, targetTop: 500, targetBottom: 540, viewportHeight: 400, contentHeight: 4000 })
    expect(near).toEqual({ targetOffset: 320, animatedStartOffset: 0, usesLongDistanceJump: false })
    const far = unreadScrollPlan({ currentOffset: 0, targetTop: 3000, targetBottom: 3040, viewportHeight: 400, contentHeight: 4000 })
    expect(far.targetOffset).toBe(2820)
    expect(far.usesLongDistanceJump).toBe(true)
    expect(far.animatedStartOffset).toBe(2420)
    const end = unreadScrollPlan({ currentOffset: 0, targetTop: 3960, targetBottom: 4000, viewportHeight: 400, contentHeight: 4000 })
    expect(end.targetOffset).toBe(3600)
  })
})
