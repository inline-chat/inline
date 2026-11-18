import { describe, expect, it } from "vitest"
import { UNREAD_LINE_KEY, messageItemKey } from "./items"
import { history, mid, msg } from "./testing/fixtures"
import { createHarness, LIVE, type Harness } from "./testing/harness"

const key = (id: number) => messageItemKey(msg(id))
const near = (actual: number, expected: number) => expect(Math.abs(actual - expected)).toBeLessThanOrEqual(0.5)
const atBottom = (h: Harness) => expect(Math.abs(h.distance())).toBeLessThanOrEqual(1)

/** The latest page only: the unread history around message 100 is not cached. */
const LATEST_PAGE = { ...LIVE, hasOlder: true }
const AROUND = { hasOlder: true, hasNewer: true, atLatest: false, loading: "none" as const }

describe("opening at the unread line, cached (rule 1)", () => {
  it("opens with the line at the top in the first frame", () => {
    const h = createHarness()
    h.open({ kind: "unread", boundary: mid(150) }, history(1, 200))
    expect(h.controller.mode.peek()).toBe("restoring")
    expect(h.controller.hidden.peek()).toBe(false)
    near(h.top(UNREAD_LINE_KEY), 0)
    expect(h.top(key(151))).toBeGreaterThan(h.top(UNREAD_LINE_KEY))
    expect(h.controller.latestButton.peek().visible).toBe(true)
  })

  it("opens with the line under a translucent header", () => {
    const h = createHarness({ insets: { top: 52, bottom: 0 } })
    h.open({ kind: "unread", boundary: mid(150) }, history(1, 200))
    near(h.top(UNREAD_LINE_KEY), 52)
  })

  it("opens at the bottom when the rows from the line down fit on screen", () => {
    const h = createHarness()
    h.open({ kind: "unread", boundary: mid(197) }, history(1, 200))
    expect(h.controller.mode.peek()).toBe("following")
    atBottom(h)
    expect(h.fake.rowTop(UNREAD_LINE_KEY)).toBeDefined()
  })

  it("keeps the line fixed while messages are read and arrive", () => {
    const h = createHarness()
    h.open({ kind: "unread", boundary: mid(150) }, history(1, 200))
    const keys = () => h.items.map((item) => item.key)
    const lineIndex = () => keys().indexOf(UNREAD_LINE_KEY)
    expect(keys()[lineIndex() + 1]).toBe(key(151))
    h.controller.setReadState({ unreadCount: 0, readMaxId: mid(200) })
    h.update(history(1, 205))
    expect(keys()[lineIndex() + 1]).toBe(key(151))
    near(h.top(UNREAD_LINE_KEY), 0)
  })

  it("holds the line through media loads above, width, composer and inset changes", () => {
    const h = createHarness()
    h.open({ kind: "unread", boundary: mid(150) }, history(1, 200))
    h.resize(key(140), 420)
    h.frame()
    near(h.top(UNREAD_LINE_KEY), 0)

    h.fake.resizeViewport(480)
    h.frame()
    near(h.top(UNREAD_LINE_KEY), 0)

    for (const k of h.fake.keys()) if (k.startsWith("m:")) h.resize(k, 77.7)
    h.fake.resizeViewport(560)
    h.frame()
    near(h.top(UNREAD_LINE_KEY), 0)

    h.setInsets({ top: 40, bottom: 80 })
    h.frame()
    near(h.top(UNREAD_LINE_KEY), 40)
    expect(h.controller.mode.peek()).toBe("restoring")
  })

  it("holds through older history arriving above", () => {
    const h = createHarness()
    h.open({ kind: "unread", boundary: mid(150) }, history(100, 200))
    h.update(history(1, 200), { ...LIVE, hasOlder: false })
    near(h.top(UNREAD_LINE_KEY), 0)
  })

  it("releases the hold on user input; the place is then the reader's", () => {
    const h = createHarness()
    h.open({ kind: "unread", boundary: mid(150) }, history(1, 200))
    h.scroll(40)
    expect(h.controller.mode.peek()).toBe("reading")
    expect(h.controller.debug().hold).toBeNull()
    const line = h.top(UNREAD_LINE_KEY)
    h.resize(key(140), 300)
    h.frame()
    near(h.top(UNREAD_LINE_KEY), line)
  })

  it("marks nothing read before the list has landed", () => {
    const h = createHarness()
    h.open({ kind: "unread", boundary: mid(150) }, history(1, 200))
    expect(h.reads.every((read) => read.kind === "readUpTo")).toBe(true)
    expect(h.reads.at(-1)?.maxId).toBeDefined()
    // The highest message on screen below the line, not the end of the chat.
    expect(Number(h.reads.at(-1)!.maxId)).toBeLessThan(200)
  })
})

describe("opening at the unread line, not cached", () => {
  const openUncached = () => {
    const h = createHarness()
    h.open({ kind: "unread", boundary: mid(100) }, history(150, 200), LATEST_PAGE)
    return h
  }

  it("stays hidden while history around the line loads, then places once and reveals", () => {
    const h = openUncached()
    expect(h.controller.hidden.peek()).toBe(true)
    expect(h.controller.mode.peek()).toBe("restoring")
    expect(h.requests).toEqual([{ around: mid(100) }])

    h.update(history(150, 200), { ...LATEST_PAGE, loading: "initial" })
    h.update(history(56, 145), AROUND)
    // Placed in the commit, still hidden for this frame.
    near(h.top(UNREAD_LINE_KEY), 0)
    expect(h.controller.hidden.peek()).toBe(true)
    h.frame()
    expect(h.controller.hidden.peek()).toBe(false)
    expect(h.controller.spinner.peek()).toBe(false)
    near(h.top(UNREAD_LINE_KEY), 0)
    expect(h.controller.mode.peek()).toBe("restoring")
    expect(h.reads.length).toBeGreaterThan(0)
  })

  it("shows the spinner only after 250 ms", () => {
    const h = openUncached()
    h.advance(240)
    expect(h.controller.spinner.peek()).toBe(false)
    h.advance(16)
    expect(h.controller.spinner.peek()).toBe(true)
    h.update(history(56, 145), AROUND)
    h.frame()
    expect(h.controller.spinner.peek()).toBe(false)
    expect(h.controller.hidden.peek()).toBe(false)
  })

  it("never shows the spinner for a fast fetch", () => {
    const h = openUncached()
    const seen: boolean[] = []
    for (let i = 0; i < 6; i++) {
      h.frame()
      seen.push(h.controller.spinner.peek())
    }
    h.update(history(56, 145), AROUND)
    for (let i = 0; i < 30; i++) {
      h.frame()
      seen.push(h.controller.spinner.peek())
    }
    expect(seen.every((shown) => !shown)).toBe(true)
  })

  it("marks nothing read while hidden", () => {
    const h = openUncached()
    h.advance(500)
    expect(h.reads).toEqual([])
  })

  it.each([
    ["the connection is lost", (h: Harness) => h.controller.connectionLost()],
    ["the user sends", (h: Harness) => h.controller.userSent()],
    ["the user jumps to latest", (h: Harness) => h.controller.jumpToLatest()],
  ])("shows latest instead when %s", (_name, act) => {
    const h = openUncached()
    h.advance(300)
    h.act(() => act(h))
    h.frame()
    expect(h.controller.hidden.peek()).toBe(false)
    expect(h.controller.spinner.peek()).toBe(false)
    expect(h.controller.mode.peek()).toBe("following")
    atBottom(h)
    // A late answer does not move the list any more.
    const offset = h.fake.offset()
    h.update(history(150, 201), LATEST_PAGE)
    expect(h.fake.offset()).toBeGreaterThanOrEqual(offset)
    expect(h.fake.rowTop(UNREAD_LINE_KEY)).toBeUndefined()
    atBottom(h)
  })

  it("shows latest when the fetch settles without the line", () => {
    const h = openUncached()
    h.update(history(150, 200), { ...LATEST_PAGE, loading: "initial" })
    expect(h.controller.hidden.peek()).toBe(true)
    h.update(history(150, 200), LATEST_PAGE)
    h.frame()
    expect(h.controller.hidden.peek()).toBe(false)
    expect(h.controller.mode.peek()).toBe("following")
    atBottom(h)
  })

  it("opens at latest when everything is loaded and nothing unread is shown", () => {
    const h = createHarness()
    h.open({ kind: "unread", boundary: mid(200) }, history(1, 200), { ...LIVE, hasOlder: false })
    expect(h.controller.hidden.peek()).toBe(false)
    expect(h.controller.mode.peek()).toBe("following")
    atBottom(h)
  })
})

describe("saved places", () => {
  it("captures the reading place when scrolling goes idle and clears it when the newest message is on screen", () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(1, 200))
    h.scroll(-900)
    expect(h.places).toEqual([])
    h.advance(200)
    const place = h.places.at(-1)!
    expect(place).not.toBeNull()
    const reading = messageItemKey(msg(Number(place.messageId)))
    near(h.top(reading), place.offset)

    // Left a few lines up: the newest message is on screen, so the chat reopens at the bottom.
    h.scrollAndSettle(885)
    expect(h.places.at(-1)).toBeNull()
  })

  it("reopens at a saved place, held until the user moves", () => {
    const first = createHarness()
    first.open({ kind: "latest" }, history(1, 200))
    first.scrollAndSettle(-1234)
    first.controller.dispose()
    const place = first.places.at(-1)!

    const h = createHarness()
    h.open({ kind: "place", place }, history(1, 200))
    expect(h.controller.mode.peek()).toBe("restoring")
    near(h.top(messageItemKey(msg(Number(place.messageId)))), place.offset)
    h.resize(key(150), 333)
    h.frame()
    near(h.top(messageItemKey(msg(Number(place.messageId)))), place.offset)
  })

  it("opens at latest when the saved message is gone", () => {
    const h = createHarness()
    h.open({ kind: "place", place: { messageId: mid(9999), offset: 10 } }, history(1, 200))
    expect(h.controller.mode.peek()).toBe("following")
    atBottom(h)
  })

  it("does not save the place being left when jumping to latest", () => {
    const h = createHarness()
    h.open({ kind: "latest" }, history(1, 400))
    h.scrollAndSettle(-1500)
    const saved = h.places.length
    h.act(() => h.controller.jumpToLatest())
    h.advance(1000)
    expect(h.places.slice(saved).every((place) => place === null)).toBe(true)
  })
})

describe("opening at a message", () => {
  it("centers a loaded message and highlights it", () => {
    const h = createHarness()
    h.open({ kind: "message", messageId: mid(120) }, history(1, 200))
    const rect = h.fake.host.rowRect(key(120))!
    near((rect.top + rect.bottom) / 2, 300)
    expect(h.controller.highlight.peek()?.key).toBe(key(120))
    expect(h.controller.mode.peek()).toBe("reading")
  })

  it("stays hidden until a message that is not loaded lands, never painting the bottom first", () => {
    const h = createHarness()
    h.open({ kind: "message", messageId: mid(50) }, history(150, 200), LATEST_PAGE)
    expect(h.controller.hidden.peek()).toBe(true)
    expect(h.requests).toEqual([{ around: mid(50) }])
    h.update(history(20, 80), AROUND)
    h.advance(500)
    expect(h.controller.hidden.peek()).toBe(false)
    const rect = h.fake.host.rowRect(key(50))!
    near((rect.top + rect.bottom) / 2, 300)
    expect(h.controller.highlight.peek()?.key).toBe(key(50))
  })
})

describe("a core that answers synchronously", () => {
  it("receives requests only after the controller's call has finished, so its answer is applied whole", () => {
    let h!: Harness
    let stateWhenAsked: number | undefined
    h = createHarness({
      onRequest: (range) => {
        if (typeof range === "object" && "around" in range) {
          // The opening items must already be published when the core is asked.
          stateWhenAsked = h.controller.items.peek().length
          h.update(history(56, 145), AROUND)
        }
      },
    })
    h.open({ kind: "unread", boundary: mid(100) }, history(150, 200), LATEST_PAGE)
    h.frame()
    expect(stateWhenAsked).toBeGreaterThan(0)
    expect(h.controller.hidden.peek()).toBe(false)
    expect(h.controller.mode.peek()).toBe("restoring")
    near(h.top(UNREAD_LINE_KEY), 0)
  })
})
