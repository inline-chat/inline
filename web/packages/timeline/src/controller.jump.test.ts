import { describe, expect, it } from "vitest"
import { messageItemKey } from "./items"
import { history, mid, msg } from "./testing/fixtures"
import { createHarness, LIVE, type Harness } from "./testing/harness"

const key = (id: number) => messageItemKey(msg(id))
const idOf = (k: string) => Number(k.split(":")[2])
const atBottom = (h: Harness) => expect(Math.abs(h.distance())).toBeLessThanOrEqual(1)
const centered = (h: Harness, k: string) => {
  const rect = h.fake.host.rowRect(k)!
  expect(Math.abs((rect.top + rect.bottom) / 2 - 300)).toBeLessThanOrEqual(1)
}
const LATEST_PAGE = { ...LIVE, hasOlder: true }
const AROUND = { hasOlder: true, hasNewer: true, atLatest: false, loading: "none" as const }

const openAtLatest = () => {
  const h = createHarness()
  h.open({ kind: "latest" }, history(1, 200))
  return h
}

/** A rendered message whose top is about `above` px above the viewport top. */
const rowAbove = (h: Harness, above: number) =>
  h.fake
    .keys()
    .filter((k) => k.startsWith("m:"))
    .reduce((best, k) => (Math.abs(h.top(k) + above) < Math.abs(h.top(best) + above) ? k : best))

describe("jump to a message in the window", () => {
  it("animates a near jump once in 0.4 s, centers, highlights and reads", () => {
    const h = openAtLatest()
    const target = rowAbove(h, 500)
    h.act(() => h.controller.jumpToMessage(mid(idOf(target))))
    expect(h.controller.mode.peek()).toBe("target")
    h.advance(208)
    expect(h.controller.debug().animating).toBe(true)
    expect(h.controller.highlight.peek()).toBeNull()
    h.advance(208)
    expect(h.controller.debug().animating).toBe(false)
    centered(h, target)
    expect(h.controller.highlight.peek()?.key).toBe(target)
    expect(h.controller.mode.peek()).toBe("reading")
  })

  it("travels a far jump in two phases: 0.3 s to half a viewport short, then 0.4 s onto it", () => {
    const h = openAtLatest()
    const target = rowAbove(h, 2000)
    const from = h.fake.offset()
    const offsets: number[] = []
    h.act(() => h.controller.jumpToMessage(mid(idOf(target))))
    for (let t = 0; t < 900; t += 16) {
      h.frame()
      offsets.push(h.fake.offset())
    }
    const to = h.fake.offset()
    expect(from - to).toBeGreaterThan(1200)
    centered(h, target)
    // Phase 1 ends exactly half a viewport below the target, at 0.3 s.
    const short = Math.round(to + 300)
    const phaseEnd = offsets.indexOf(short)
    expect(phaseEnd).toBeGreaterThan(0)
    expect((phaseEnd + 1) * 16).toBeGreaterThanOrEqual(300)
    expect((phaseEnd + 1) * 16).toBeLessThan(300 + 32)
    const landed = offsets.indexOf(to)
    expect((landed + 1) * 16).toBeGreaterThanOrEqual(700)
    expect((landed + 1) * 16).toBeLessThan(700 + 48)
    // Monotonic travel: no overshoot or bounce.
    for (let i = 1; i < offsets.length; i++) expect(offsets[i]!).toBeLessThanOrEqual(offsets[i - 1]!)
  })

  it("is cancelled by user input mid-animation, in the same event", () => {
    const h = openAtLatest()
    const target = h.fake.keys().find((k) => k.startsWith("m:"))!
    h.act(() => h.controller.jumpToMessage(mid(idOf(target))))
    h.advance(150)
    expect(h.controller.debug().animating).toBe(true)
    h.fake.userScroll(-30)
    expect(h.controller.debug().animating).toBe(false)
    expect(h.controller.mode.peek()).toBe("reading")
    const offset = h.fake.offset()
    const writes = h.fake.writes()
    h.advance(1000)
    expect(h.fake.writes()).toBe(writes)
    expect(h.fake.offset()).toBe(offset)
    expect(h.controller.highlight.peek()).toBeNull()
  })

  it("re-aims when a row above the target changes size during the jump", () => {
    const h = openAtLatest()
    const target = rowAbove(h, 700)
    h.act(() => h.controller.jumpToMessage(mid(idOf(target))))
    h.advance(160)
    const above = h.fake.keys().find((k) => k.startsWith("m:"))!
    h.resize(above, 500)
    h.advance(600)
    centered(h, target)
  })
})

describe("jump to a message outside the window", () => {
  it("asks for the rows around it, then lands with one easing in, centered and highlighted", () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(150, 200), LATEST_PAGE)
    h.act(() => h.controller.jumpToMessage(mid(50)))
    expect(h.requests).toEqual([{ around: mid(50) }])
    expect(h.controller.mode.peek()).toBe("target")
    h.update(history(20, 80), AROUND)
    // Starts half a viewport short, below the older target, and travels up.
    const rect = h.fake.host.rowRect(key(50))!
    expect((rect.top + rect.bottom) / 2).toBeLessThan(0)
    h.advance(450)
    centered(h, key(50))
    expect(h.controller.highlight.peek()?.key).toBe(key(50))
    expect(h.controller.mode.peek()).toBe("reading")
  })

  it("renders loaded rows that were trimmed away and lands on them", () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(1, 400))
    expect(h.fake.rowTop(key(10))).toBeUndefined()
    h.act(() => h.controller.jumpToMessage(mid(10)))
    expect(h.requests).toEqual([])
    h.advance(450)
    centered(h, key(10))
  })

  it("lands on the nearest message when the target is gone, without a highlight", () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(150, 200), LATEST_PAGE)
    h.act(() => h.controller.jumpToMessage(mid(60)))
    h.update(history(20, 80).filter((row) => row.messageId !== mid(60)), AROUND)
    h.advance(450)
    centered(h, key(61))
    expect(h.controller.highlight.peek()).toBeNull()
  })

  it("is abandoned when the user scrolls before the rows arrive", () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(150, 200), LATEST_PAGE)
    h.act(() => h.controller.jumpToMessage(mid(50)))
    h.scroll(-40)
    expect(h.controller.mode.peek()).toBe("reading")
    expect(h.controller.debug().jump).toBeNull()
    h.update(history(150, 200), LATEST_PAGE)
    h.advance(500)
    expect(h.controller.highlight.peek()).toBeNull()
    expect(h.controller.debug().animating).toBe(false)
  })
})

describe("jump to latest", () => {
  it("animates to the bottom in the window and follows again", () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(1, 200))
    h.scrollAndSettle(-1500)
    expect(h.controller.latestButton.peek().visible).toBe(true)
    h.act(() => h.controller.jumpToLatest())
    expect(h.controller.mode.peek()).toBe("target")
    h.advance(800)
    expect(h.controller.mode.peek()).toBe("following")
    atBottom(h)
    expect(h.controller.latestButton.peek().visible).toBe(false)
  })

  it("loads latest when the window is in history, then lands at the bottom", () => {
    const h = createHarness()
    h.open({ kind: "message", messageId: mid(50) }, history(20, 80), AROUND)
    h.act(() => h.controller.jumpToLatest())
    expect(h.requests).toEqual(["latest"])
    h.update(history(150, 200), LATEST_PAGE)
    h.advance(500)
    expect(h.controller.mode.peek()).toBe("following")
    atBottom(h)
  })

  it("happens when the user sends while reading history", () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(1, 200))
    h.scrollAndSettle(-1500)
    h.act(() => h.controller.userSent())
    h.advance(800)
    expect(h.controller.mode.peek()).toBe("following")
    atBottom(h)
  })
})

describe("mode transitions", () => {
  it("walks every transition", () => {
    const h = createHarness()
    const seen: string[] = []
    const note = () => {
      const mode = h.controller.mode.peek()
      if (seen.at(-1) !== mode) seen.push(mode)
    }
    h.open({ kind: "latest" }, history(1, 200))
    note() // following
    h.fake.userScroll(-100)
    note() // following -> reading (input)
    h.frame()
    h.scroll(95)
    note() // reading -> following (back in the zone)
    h.advance(200)
    h.act(() => h.controller.jumpToMessage(mid(190)))
    note() // following -> target
    h.advance(500)
    note() // target -> reading (landed)
    h.act(() => h.controller.jumpToLatest())
    note() // reading -> target
    h.advance(800)
    note() // target -> following
    h.open({ kind: "unread", boundary: mid(150) }, history(1, 200))
    note() // -> restoring
    h.scroll(30)
    note() // restoring -> reading (input releases the hold)
    h.advance(200)
    h.act(() => h.controller.jumpToMessage(mid(20)))
    note() // reading -> target
    h.advance(100)
    h.fake.userScroll(-10)
    note() // target -> reading (input cancels)
    h.advance(200)
    h.open({ kind: "unread", boundary: mid(100) }, history(150, 200), LATEST_PAGE)
    note() // -> restoring, hidden
    h.update(history(56, 145), AROUND)
    h.frame()
    note() // restoring, placed and revealed
    h.act(() => h.controller.jumpToMessage(mid(60)))
    note() // restoring -> target
    expect(seen).toEqual([
      "following",
      "reading",
      "following",
      "target",
      "reading",
      "target",
      "following",
      "restoring",
      "reading",
      "target",
      "reading",
      "restoring",
      "target",
    ])
  })
})
