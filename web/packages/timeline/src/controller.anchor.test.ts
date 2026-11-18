import { describe, expect, it } from "vitest"
import { messageItemKey } from "./items"
import { createFakeHost } from "./testing/fake-host"
import { history, msg } from "./testing/fixtures"
import { createHarness, LIVE } from "./testing/harness"

/** Budget from performance.md: under 1 px after any operation, nothing accumulating. */
const BUDGET = 1
const key = (id: number) => messageItemKey(msg(id))

/** A reader in the middle of a long history, with rows above and below rendered. */
const readingInHistory = (options: Parameters<typeof createHarness>[0] = {}) => {
  const h = createHarness(options)
  h.open({ kind: "latest" }, history(101, 400))
  h.scrollAndSettle(-1500)
  expect(h.controller.mode.peek()).toBe("reading")
  return h
}

describe("anchor capture", () => {
  it("captures every visible message row in reading order, rows starting on screen first", () => {
    const h = readingInHistory()
    const anchors = h.controller.debug().anchors
    const visible = h.fake.host.visibleKeys().filter((k) => k.startsWith("m:"))
    expect(new Set(anchors.map((a) => a.key))).toEqual(new Set(visible))
    const started = anchors.filter((a) => a.offset >= 0)
    expect(anchors.slice(0, started.length)).toEqual(started)
    expect(started.map((a) => a.offset)).toEqual(started.map((a) => a.offset).sort((a, b) => a - b))
    expect(anchors[0]!.key).toBe(h.reading())
  })

  it("keeps the next surviving row in place when the anchored row is deleted", () => {
    const h = readingInHistory()
    const reading = h.reading()
    const anchors = h.controller.debug().anchors.map((a) => a.key)
    const next = anchors[1]!
    const before = h.top(next)
    const deletedId = Number(reading.split(":")[2])
    h.update(h.rows.filter((row) => Number(row.messageId) !== deletedId))
    expect(h.fake.rowTop(reading)).toBeUndefined()
    expect(Math.abs(h.top(next) - before)).toBeLessThan(BUDGET)
  })

  it("keeps the reader in place when several anchored rows and rows above are deleted", () => {
    const h = readingInHistory()
    const anchors = h.controller.debug().anchors.map((a) => a.key)
    const survivor = anchors[3]!
    const before = h.top(survivor)
    const gone = new Set([...anchors.slice(0, 3), ...h.fake.keys().filter((k) => k.startsWith("m:")).slice(0, 5)])
    h.update(h.rows.filter((row) => !gone.has(messageItemKey(row))))
    expect(Math.abs(h.top(survivor) - before)).toBeLessThan(BUDGET)
  })
})

describe("compensation: zero net drift of the anchored row", () => {
  it("on prepend, in the same commit as the rows are inserted", () => {
    const h = readingInHistory()
    h.scroll(-2000)
    h.advance(200)
    const reading = h.reading()
    const before = h.top(reading)
    // Older rows arrive and render above: corrected before any frame passes.
    h.update(history(1, 400), { ...LIVE, hasOlder: false })
    expect(Math.abs(h.top(reading) - before)).toBeLessThan(BUDGET)
    h.frame()
    expect(Math.abs(h.top(reading) - before)).toBeLessThan(BUDGET)
  })

  it("on a resize above the anchor (a media load)", () => {
    const h = readingInHistory()
    const reading = h.reading()
    const before = h.top(reading)
    const above = h.fake.keys().find((k) => k.startsWith("m:"))!
    h.resize(above, 412.4)
    h.frame()
    expect(Math.abs(h.top(reading) - before)).toBeLessThan(BUDGET)
  })

  it("on a viewport resize (the composer grows)", () => {
    const h = readingInHistory()
    const reading = h.reading()
    const before = h.top(reading)
    h.fake.resizeViewport(520)
    h.frame()
    expect(Math.abs(h.top(reading) - before)).toBeLessThan(BUDGET)
  })

  it("on a width change: every row above re-wraps and the viewport changes", () => {
    const h = readingInHistory()
    const reading = h.reading()
    const before = h.top(reading)
    h.fake.resizeViewport(640)
    for (const k of h.fake.keys()) if (k.startsWith("m:")) h.resize(k, (h.fake.host.rowRect(k)!.bottom - h.fake.host.rowRect(k)!.top) * 1.37)
    h.frame()
    expect(Math.abs(h.top(reading) - before)).toBeLessThan(BUDGET)
  })

  it("while a streaming row grows below the reader: nothing visible moves", () => {
    const h = readingInHistory()
    const reading = h.reading()
    const before = h.top(reading)
    const offset = h.fake.offset()
    for (let i = 1; i <= 60; i++) {
      h.resize(key(400), 60 + i * 13.7)
      h.frame()
      expect(h.top(reading)).toBe(before)
    }
    expect(h.fake.offset()).toBe(offset)
    expect(h.controller.mode.peek()).toBe("reading")
  })

  it("while the anchored row itself streams: it grows downward", () => {
    const h = readingInHistory()
    const reading = h.reading()
    const before = h.top(reading)
    for (let i = 1; i <= 20; i++) {
      h.resize(reading, 60 + i * 9.1)
      h.frame()
    }
    expect(h.top(reading)).toBe(before)
  })

  it("lets a row cut by the top edge grow out of sight", () => {
    const h = readingInHistory()
    const cut = h.fake.host.visibleKeys().find((k) => k.startsWith("m:") && h.top(k) < 0)
    if (!cut) h.scroll(-17)
    h.advance(200)
    const top = h.fake.host.visibleKeys().find((k) => k.startsWith("m:") && h.top(k) < 0)!
    const reading = h.reading()
    const before = h.top(reading)
    h.resize(top, 300)
    h.frame()
    expect(Math.abs(h.top(reading) - before)).toBeLessThan(BUDGET)
  })

  it("ignores zero-size entries from hidden rows", () => {
    const h = readingInHistory()
    const reading = h.reading()
    const before = h.top(reading)
    const offset = h.fake.offset()
    h.fake.emitZeroSizes(h.fake.keys())
    h.frame()
    expect(h.fake.offset()).toBe(offset)
    // Shown again at the same sizes: still nothing to correct.
    h.fake.resizeRows(h.fake.keys().map((k) => ({ key: k, height: h.fake.host.rowRect(k)!.bottom - h.fake.host.rowRect(k)!.top })))
    h.frame()
    expect(h.top(reading)).toBe(before)
  })

  it("is right even when a scroll event captures anchors between layout and the resize observer", () => {
    const h = readingInHistory()
    const reading = h.reading()
    const before = h.top(reading)
    const above = h.fake.keys().find((k) => k.startsWith("m:"))!
    // The row above has grown in layout, its observer entry is still pending,
    // and the user's scroll event lands first in the frame.
    h.resize(above, 300)
    h.fake.userScroll(-10)
    h.frame()
    expect(Math.abs(h.top(reading) - (before + 10))).toBeLessThan(BUDGET)
  })

  it("does not accumulate over 100 prepends with fractional heights and whole-pixel scrolling", () => {
    const h = createHarness({ devicePixelRatio: 1 })
    const all = history(1, 2500)
    let start = 2400
    h.open({ kind: "latest" }, all.slice(start - 1), { ...LIVE, hasOlder: true })
    h.scrollAndSettle(-1200)
    const reading = h.reading()
    const before = h.top(reading)
    for (let i = 0; i < 100; i++) {
      start -= 3
      h.update(all.slice(start - 1))
      expect(Math.abs(h.top(reading) - before)).toBeLessThan(BUDGET)
      h.frame()
    }
    expect(Math.abs(h.top(reading) - before)).toBeLessThan(BUDGET)
  })

  it("does not accumulate over 100 sub-pixel resizes above the anchor", () => {
    const h = readingInHistory({ devicePixelRatio: 1 })
    const reading = h.reading()
    const before = h.top(reading)
    const above = h.fake.keys().find((k) => k.startsWith("m:"))!
    let height = h.fake.host.rowRect(above)!.bottom - h.fake.host.rowRect(above)!.top
    for (let i = 0; i < 100; i++) {
      height += 0.3
      h.resize(above, height)
      h.frame()
      expect(Math.abs(h.top(reading) - before)).toBeLessThan(BUDGET)
    }
    // 30 px of growth, each step under the write threshold, with nothing lost.
    expect(Math.abs(h.top(reading) - before)).toBeLessThan(BUDGET)
  })

  it("does not accumulate over 100 mixed operations", () => {
    const h = readingInHistory({ devicePixelRatio: 1 })
    const reading = h.reading()
    const before = h.top(reading)
    const rowsAbove = () => h.fake.keys().filter((k) => k.startsWith("m:") && h.top(k) < -100)
    for (let i = 0; i < 100; i++) {
      const above = rowsAbove()
      const target = above[i % above.length]!
      switch (i % 4) {
        case 0:
          h.resize(target, 40 + ((i * 37) % 90) + 0.37)
          break
        case 1:
          h.fake.resizeViewport(600 - (i % 7) * 11.5)
          break
        case 2:
          h.resize(key(400), 80 + i * 3.3)
          break
        case 3:
          h.resize(target, 33.33)
          break
      }
      h.frame()
      expect(Math.abs(h.top(reading) - before)).toBeLessThan(BUDGET)
    }
  })

  it("does not accumulate on a 2x display either", () => {
    const h = readingInHistory({ devicePixelRatio: 2 })
    const reading = h.reading()
    const before = h.top(reading)
    const above = h.fake.keys().find((k) => k.startsWith("m:"))!
    for (let i = 0; i < 100; i++) {
      h.resize(above, 50 + (i % 2 === 0 ? 0.33 : 0.71) * i)
      h.frame()
    }
    expect(Math.abs(h.top(reading) - before)).toBeLessThan(BUDGET)
  })
})

describe("resident chats", () => {
  it("puts a re-attached reader back at their anchor", () => {
    const h = readingInHistory()
    const reading = h.reading()
    const before = h.top(reading)
    h.controller.detach()
    // A new element for the same chat, rendered from the top.
    const fresh = createFakeHost({ viewportHeight: 600, devicePixelRatio: 1 })
    fresh.setRows(h.fake.keys().map((k) => ({ key: k, height: h.fake.host.rowRect(k)!.bottom - h.fake.host.rowRect(k)!.top })))
    h.controller.attach(fresh.host)
    expect(Math.abs(fresh.rowTop(reading)! - before)).toBeLessThan(BUDGET)
  })
})
