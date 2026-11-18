import { describe, expect, it } from "vitest"
import { messageItemKey } from "./items"
import { history, mid, msg } from "./testing/fixtures"
import { createHarness, type Harness } from "./testing/harness"

const atBottom = (h: Harness) => expect(Math.abs(h.distance())).toBeLessThanOrEqual(1)
const key = (id: number) => messageItemKey(msg(id))

const openAtLatest = () => {
  const h = createHarness()
  h.open({ kind: "latest" }, history(1, 200))
  return h
}

describe("following latest", () => {
  it("opens at the bottom in the first frame", () => {
    const h = openAtLatest()
    expect(h.controller.mode.peek()).toBe("following")
    atBottom(h)
    expect(h.controller.latestButton.peek()).toEqual({ visible: false, count: 0 })
    expect(h.controller.hidden.peek()).toBe(false)
  })

  it("keeps a list resting at the bottom pinned through new messages and size changes", () => {
    const h = openAtLatest()
    h.update(history(1, 201))
    atBottom(h)
    expect(h.top(key(201)) + 48.25 + (201 % 4) * 10.5).toBeCloseTo(600, 0)

    h.resize(key(201), 400)
    h.frame()
    atBottom(h)

    h.resize(key(180), 300)
    h.frame()
    atBottom(h)
    expect(h.controller.mode.peek()).toBe("following")
  })

  it("stays pinned while a streaming row grows at 60 updates a second", () => {
    const h = openAtLatest()
    for (let i = 1; i <= 60; i++) {
      h.resize(key(200), 60 + i * 7.3)
      h.frame()
      atBottom(h)
    }
  })

  it("detaches on one upward wheel tick, before its scroll event arrives", () => {
    const h = openAtLatest()
    h.fake.userScroll(-10)
    expect(h.controller.mode.peek()).toBe("reading")
    h.frame()
    expect(h.controller.mode.peek()).toBe("reading")
    expect(h.controller.latestButton.peek().visible).toBe(true)
  })

  it("does not reattach a reader who moved up inside the follow zone", () => {
    const h = openAtLatest()
    h.scrollAndSettle(-20)
    expect(h.distance()).toBeLessThan(44)
    expect(h.controller.mode.peek()).toBe("reading")
  })

  it("reattaches a reader coming back down inside the 44 px follow zone", () => {
    const h = openAtLatest()
    h.scrollAndSettle(-200)
    expect(h.controller.mode.peek()).toBe("reading")
    h.scroll(150)
    expect(h.distance()).toBeGreaterThan(44)
    expect(h.controller.mode.peek()).toBe("reading")
    h.scroll(20)
    expect(h.distance()).toBeLessThanOrEqual(44)
    expect(h.distance()).toBeGreaterThan(1)
    expect(h.controller.mode.peek()).toBe("following")
    h.advance(200)

    // A new message pulls a follower in the zone down to the bottom.
    h.update(history(1, 201))
    atBottom(h)
  })

  it("only pins at the exact bottom: inside the zone a size change holds the reading row", () => {
    const h = openAtLatest()
    h.scrollAndSettle(-200)
    h.scrollAndSettle(170)
    expect(h.controller.mode.peek()).toBe("following")
    const distance = h.distance()
    expect(distance).toBeGreaterThan(1)

    const reading = h.reading()
    const before = h.top(reading)
    const offset = h.fake.offset()
    h.resize(h.fake.keys().find((k) => k.startsWith("m:"))!, 200)
    h.frame()
    expect(Math.abs(h.top(reading) - before)).toBeLessThan(1)
    expect(h.fake.offset()).toBeGreaterThan(offset)

    // The last row streams: it grows downward, nothing on screen moves, the mode stays.
    const atStream = h.top(reading)
    h.resize(key(200), 500)
    h.frame()
    expect(h.top(reading)).toBe(atStream)
    expect(h.controller.mode.peek()).toBe("following")
  })

  it("never moves, detaches or reattaches a reader when rows arrive below", () => {
    const h = openAtLatest()
    h.scrollAndSettle(-20)
    const reading = h.reading()
    const before = h.top(reading)
    for (let id = 201; id <= 210; id++) {
      h.update(history(1, id))
      h.frame()
      expect(h.top(reading)).toBe(before)
      expect(h.controller.mode.peek()).toBe("reading")
    }
    expect(h.controller.latestButton.peek().visible).toBe(true)
  })

  it("ignores the scroll event of its own correction", () => {
    const h = openAtLatest()
    h.scrollAndSettle(-200)
    h.scrollAndSettle(170)
    expect(h.controller.mode.peek()).toBe("following")
    const first = h.fake.keys().find((k) => k.startsWith("m:"))!
    // A row above shrinks: the correction moves the offset up, which a naive
    // listener would read as the user scrolling away from the bottom.
    h.resize(first, 20)
    h.frame()
    h.frame()
    h.frame()
    expect(h.controller.mode.peek()).toBe("following")
    expect(h.controller.debug().scrolledAway).toBe(false)
    h.update(history(1, 201))
    atBottom(h)
  })

  it("does not follow while the user is scrolling", () => {
    const h = openAtLatest()
    h.fake.userInput("touch", undefined, true)
    const offset = h.fake.offset()
    h.update(history(1, 201))
    h.frame()
    expect(h.fake.offset()).toBe(offset)
    h.fake.inputEnd()
    h.advance(200)
    expect(h.controller.debug().userScrolling).toBe(false)
    expect(h.fake.offset()).toBe(offset)
  })

  it("ends a gesture on scrollend without waiting for the idle timer", () => {
    const h = openAtLatest()
    h.scroll(-100)
    expect(h.controller.debug().userScrolling).toBe(true)
    h.fake.scrollEnd()
    expect(h.controller.debug().userScrolling).toBe(false)
  })

  it("holds a gesture open while a touch is down, however long it pauses", () => {
    const h = openAtLatest()
    h.fake.userInput("touch", "up", true)
    h.advance(1000)
    expect(h.controller.debug().userScrolling).toBe(true)
    h.fake.inputEnd()
    h.advance(200)
    expect(h.controller.debug().userScrolling).toBe(false)
  })

  it("treats a scroll it did not cause, outside a gesture, as the reader moving", () => {
    const h = openAtLatest()
    // Find in page or a focused element scrolls the container without wheel or touch input.
    h.fake.host.setScrollOffset(1000)
    h.frame()
    expect(h.controller.mode.peek()).toBe("reading")
    expect(h.controller.debug().anchors.length).toBeGreaterThan(0)
  })

  it("reattaches when the browser clamps a reader to the bottom of a shorter list", () => {
    const h = openAtLatest()
    h.scrollAndSettle(-100)
    expect(h.controller.mode.peek()).toBe("reading")
    // The newest rows are deleted: the list gets shorter and the browser clamps the offset.
    h.update(history(1, 190))
    h.frame()
    h.frame()
    atBottom(h)
    expect(h.controller.mode.peek()).toBe("following")
  })

  it("shows jump to latest with the unread count while reading", () => {
    const h = openAtLatest()
    h.controller.setReadState({ unreadCount: 3, readMaxId: mid(200) })
    h.scrollAndSettle(-300)
    expect(h.controller.latestButton.peek()).toEqual({ visible: true, count: 3 })
  })
})
