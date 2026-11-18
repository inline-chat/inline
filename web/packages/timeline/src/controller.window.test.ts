import { describe, expect, it } from "vitest"
import { messageItemKey } from "./items"
import { TRIM_ABOVE_ROWS, TRIM_TO_ROWS } from "./constants"
import { history, mid, msg } from "./testing/fixtures"
import { createHarness, LIVE } from "./testing/harness"

const key = (id: number) => messageItemKey(msg(id))
const rendered = (h: ReturnType<typeof createHarness>) => {
  const { start, end } = h.controller.range.peek()
  return end - start
}
const LATEST_PAGE = { ...LIVE, hasOlder: true }

describe("window growth", () => {
  it("sizes the first window from the viewport", () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(1, 400))
    // 600 / 24 + 30 = 55 rows, plus the separator above the first.
    expect(rendered(h)).toBeGreaterThanOrEqual(55)
    expect(rendered(h)).toBeLessThanOrEqual(57)
  })

  it("asks for older rows within one viewport of the top, only after user movement, once", () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(150, 200), LATEST_PAGE)
    expect(h.requests).toEqual([])
    h.scroll(-(h.fake.offset() - 400))
    expect(h.requests).toEqual(["older"])
    h.scroll(-50)
    h.scroll(-50)
    expect(h.requests).toEqual(["older"])

    const reading = h.reading()
    const before = h.top(reading)
    h.update(history(100, 200), LATEST_PAGE)
    expect(Math.abs(h.top(reading) - before)).toBeLessThan(1)
    expect(h.fake.rowTop(key(100))).toBeDefined()

    // The page arrived: the next approach asks again.
    h.scroll(-(h.fake.offset() - 300))
    expect(h.requests).toEqual(["older", "older"])
  })

  it("never asks because of its own movement", () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(150, 200), LATEST_PAGE)
    h.act(() => h.controller.jumpToMessage(mid(151)))
    h.advance(800)
    expect(h.fake.offset()).toBeLessThan(600)
    expect(h.requests).toEqual([])
  })

  it("renders loaded rows above before asking the core, without drift", () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(1, 400))
    const start = h.controller.range.peek().start
    h.scroll(-(h.fake.offset() - 300))
    const reading = h.reading()
    const before = h.top(reading)
    expect(h.controller.range.peek().start).toBeLessThan(start)
    expect(h.requests).toEqual([])
    expect(Math.abs(h.top(reading) - before)).toBeLessThan(1)
  })

  it("asks for newer rows at the bottom of a window in history", () => {
    const h = createHarness()
    h.open({ kind: "message", messageId: mid(50) }, history(20, 80), {
      hasOlder: true,
      hasNewer: true,
      atLatest: false,
      loading: "none",
    })
    h.scroll(5000)
    expect(h.requests).toContain("newer")
  })
})

describe("trimming", () => {
  const grown = () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(1, 1000))
    // Scroll up continuously: the window grows by pages while the user is scrolling.
    for (let i = 0; i < 60 && rendered(h) <= TRIM_ABOVE_ROWS; i++) h.scroll(-600)
    expect(rendered(h)).toBeGreaterThan(TRIM_ABOVE_ROWS)
    return h
  }

  it("never trims while the user is scrolling", () => {
    const h = grown()
    expect(h.controller.debug().userScrolling).toBe(true)
    const size = rendered(h)
    h.scroll(-10)
    h.scroll(-10)
    expect(rendered(h)).toBeGreaterThanOrEqual(size)
  })

  it("trims to about 200 rows around the viewport once idle, with no drift", () => {
    const h = grown()
    h.advance(100)
    const reading = h.reading()
    const before = h.top(reading)
    h.advance(100)
    expect(h.controller.debug().userScrolling).toBe(false)
    expect(rendered(h)).toBeLessThanOrEqual(TRIM_TO_ROWS + 2)
    expect(rendered(h)).toBeGreaterThanOrEqual(TRIM_TO_ROWS - 2)
    expect(Math.abs(h.top(reading) - before)).toBeLessThan(1)
    // Rows on both sides of the viewport are kept.
    expect(h.fake.keys().indexOf(reading)).toBeGreaterThan(50)
    expect(h.fake.keys().length - h.fake.keys().indexOf(reading)).toBeGreaterThan(50)
  })

  it("keeps the newest rows when trimming a list that follows latest", () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(1, 200))
    let sizes = 0
    for (let id = 201; id <= 600; id++) {
      h.update(history(1, id))
      h.frame()
      sizes = Math.max(sizes, rendered(h))
      expect(Math.abs(h.distance())).toBeLessThanOrEqual(1)
    }
    expect(sizes).toBeLessThanOrEqual(TRIM_ABOVE_ROWS + 3)
    expect(rendered(h)).toBeLessThanOrEqual(TRIM_ABOVE_ROWS + 3)
    expect(h.controller.range.peek().end).toBe(h.items.length)
  })
})

describe("read marking (rule 4)", () => {
  it("reads all at the live end inside the follow zone", () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(1, 200))
    expect(h.reads).toEqual([{ kind: "readAll", maxId: mid(200) }])
    h.update(history(1, 201))
    expect(h.reads.at(-1)).toEqual({ kind: "readAll", maxId: mid(201) })
  })

  it("reads nothing while the app is inactive or hidden, then reads on return", () => {
    const h = createHarness({ activity: { visible: true, active: false } })
    h.open({ kind: "latest" }, history(1, 200))
    expect(h.reads).toEqual([])
    h.fake.setActivity({ visible: false, active: true })
    expect(h.reads).toEqual([])
    h.fake.setActivity({ visible: true, active: true })
    expect(h.reads).toEqual([{ kind: "readAll", maxId: mid(200) }])
  })

  it("in history reads up to the highest visible incoming message, never backwards", () => {
    const h = createHarness()
    h.controller.setReadState({ unreadCount: 100, readMaxId: mid(100) })
    h.open({ kind: "unread", boundary: mid(100) }, history(1, 200))
    const first = h.reads.at(-1)!
    expect(first.kind).toBe("readUpTo")
    const visible = h.fake.host.visibleKeys().filter((k) => k.startsWith("m:")).map((k) => Number(k.split(":")[2]))
    expect(Number(first.maxId)).toBe(Math.max(...visible))
    // Rule 5: the button counts what is left below.
    expect(h.controller.latestButton.peek().count).toBe(100 - (Number(first.maxId) - 100))

    h.scrollAndSettle(300)
    const second = h.reads.at(-1)!
    expect(Number(second.maxId)).toBeGreaterThan(Number(first.maxId))
    const count = h.reads.length
    h.scrollAndSettle(-600)
    expect(h.reads.length).toBe(count)
  })

  it("never reads across an uncertified hole", () => {
    const h = createHarness()
    h.controller.setReadState({ unreadCount: 100, readMaxId: mid(100) })
    h.open({ kind: "unread", boundary: mid(100) }, history(1, 200), { ...LIVE, contiguousThrough: mid(103) })
    expect(h.reads.at(-1)).toEqual({ kind: "readUpTo", maxId: mid(103) })
  })

  it("reads nothing from a window that does not reach the read marker", () => {
    const h = createHarness()
    h.controller.setReadState({ unreadCount: 100, readMaxId: mid(10) })
    h.open({ kind: "message", messageId: mid(150) }, history(120, 180), {
      hasOlder: true,
      hasNewer: true,
      atLatest: false,
      loading: "none",
    })
    h.scrollAndSettle(100)
    expect(h.reads).toEqual([])
  })
})

describe("lifecycle", () => {
  it("captures the reading place when the chat is left or disposed", () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(1, 200))
    h.fake.userScroll(-700)
    h.frame()
    h.controller.leave()
    expect(h.places.at(-1)).not.toBeNull()
    h.controller.dispose()
    h.update(history(1, 201))
    expect(h.controller.debug().userScrolling).toBe(false)
  })
})
