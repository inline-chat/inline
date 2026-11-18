import { describe, expect, it } from "vitest"
import { messageId } from "@inline/ids"
import { indexKeys, resizeDelta, structuralDelta } from "./compensation"
import { ease } from "./easing"
import {
  centeredOffset,
  decideRead,
  heldOffset,
  initialWindowSize,
  jumpToLatestCount,
  landingOffset,
  planEdges,
  planJump,
  planLanding,
  planTrim,
  withinFollowZone,
  type ReadInput,
} from "./policy"
import { ALICE, ME, mid, msg } from "./testing/fixtures"

describe("window sizes and edges", () => {
  it("sizes the first window from the viewport like the Mac (height / 24 + 30)", () => {
    expect(initialWindowSize(1000)).toBe(71)
    expect(initialWindowSize(720)).toBe(60)
    expect(initialWindowSize(0)).toBe(60)
  })

  const base = {
    offset: 5000,
    viewportHeight: 600,
    contentHeight: 20_000,
    range: { start: 100, end: 300 },
    length: 400,
    hasOlder: true,
    hasNewer: true,
    loadingOlder: false,
    loadingNewer: false,
    page: 50,
  }

  it("does nothing away from both edges", () => {
    expect(planEdges(base)).toEqual({ requests: [] })
  })

  it("renders more loaded rows near the top before asking the core", () => {
    expect(planEdges({ ...base, offset: 599 })).toEqual({ range: { start: 50, end: 300 }, requests: [] })
    expect(planEdges({ ...base, offset: 599, range: { start: 0, end: 300 } })).toEqual({ requests: ["older"] })
    expect(planEdges({ ...base, offset: 600, range: { start: 0, end: 300 } })).toEqual({ requests: [] })
  })

  it("asks once: not while a request is in flight, not past the start of history", () => {
    const top = { ...base, offset: 0, range: { start: 0, end: 300 } }
    expect(planEdges({ ...top, loadingOlder: true }).requests).toEqual([])
    expect(planEdges({ ...top, hasOlder: false }).requests).toEqual([])
  })

  it("does the same at the bottom", () => {
    const bottom = { ...base, offset: 20_000 - 600 - 100 }
    expect(planEdges(bottom)).toEqual({ range: { start: 100, end: 350 }, requests: [] })
    expect(planEdges({ ...bottom, range: { start: 100, end: 400 } })).toEqual({ requests: ["newer"] })
    expect(planEdges({ ...bottom, range: { start: 100, end: 400 }, hasNewer: false })).toEqual({ requests: [] })
  })
})

describe("trimming", () => {
  it("leaves a window of up to 300 rows alone", () => {
    expect(planTrim({ range: { start: 0, end: 300 }, firstVisible: 0, lastVisible: 10, following: false })).toBeNull()
  })

  it("keeps 200 rows centered on the viewport", () => {
    expect(planTrim({ range: { start: 0, end: 400 }, firstVisible: 190, lastVisible: 210, following: false })).toEqual({
      start: 100,
      end: 300,
    })
  })

  it("clamps to the window's edges and keeps the newest rows when following", () => {
    expect(planTrim({ range: { start: 0, end: 400 }, firstVisible: 5, lastVisible: 20, following: false })).toEqual({
      start: 0,
      end: 200,
    })
    expect(planTrim({ range: { start: 0, end: 400 }, firstVisible: 380, lastVisible: 399, following: true })).toEqual({
      start: 200,
      end: 400,
    })
  })

  it("never cuts a visible row", () => {
    const plan = planTrim({ range: { start: 0, end: 500 }, firstVisible: 100, lastVisible: 350, following: false })!
    expect(plan.start).toBeLessThanOrEqual(100)
    expect(plan.end).toBeGreaterThanOrEqual(351)
  })
})

describe("follow zone (rule 3)", () => {
  it.each([
    [0, false, true],
    [1, true, true],
    [1.5, true, false],
    [44, false, true],
    [44.5, false, false],
    [30, true, false],
  ])("distance %s, scrolled away %s: %s", (distance, away, expected) => {
    expect(withinFollowZone(distance, away)).toBe(expected)
  })
})

describe("landings (Mac UnreadLineGeometry)", () => {
  const geometry = { offset: 0, viewportHeight: 600, contentHeight: 3000, insetTop: 40 }

  it("puts the row under the top inset", () => {
    expect(landingOffset({ ...geometry, rowTop: 1000, hold: 0 })).toBe(960)
    expect(landingOffset({ ...geometry, rowTop: 1000, hold: 20 })).toBe(940)
  })

  it("opens at the bottom when the rows from the line down fit", () => {
    expect(landingOffset({ ...geometry, rowTop: 2700, hold: 0 })).toBeNull()
  })

  it("clamps a held row to the scroll range without dropping it", () => {
    expect(heldOffset({ ...geometry, rowTop: 2900, hold: 0 })).toBe(2400)
    expect(heldOffset({ ...geometry, rowTop: 10, hold: 0 })).toBe(0)
  })
})

describe("where a jump puts the row", () => {
  const base = { offset: 1000, viewportHeight: 600, contentHeight: 10_000, insetTop: 40, insetBottom: 60 }

  it("centers a row that fits in the uncovered part of the viewport", () => {
    // Uncovered part: 500 px, from 40 to 540. A 100 px row centered in it has its top at 240.
    const offset = centeredOffset({ ...base, rowTop: 900, rowBottom: 1000 })
    expect(900 - (offset - base.offset)).toBe(240)
  })

  it("puts the top of a row taller than the uncovered part at its top, not its middle", () => {
    // A photo with a long caption, 1,200 px tall: the photo must be on screen.
    const offset = centeredOffset({ ...base, rowTop: 900, rowBottom: 2100 })
    expect(900 - (offset - base.offset)).toBe(40)
  })

  it("clamps to the content", () => {
    expect(centeredOffset({ ...base, offset: 0, rowTop: 0, rowBottom: 50 })).toBe(0)
    expect(centeredOffset({ ...base, offset: 9000, rowTop: 300, rowBottom: 2000, contentHeight: 9600 })).toBe(9000)
  })
})

describe("jump plans (Mac scrollToMessage)", () => {
  it("animates a near jump once, 0.4 s ease-in-out", () => {
    expect(planJump(0, 1200, 600)).toEqual([{ to: 1200, duration: 400, easing: "easeInOut" }])
  })

  it("travels a far jump in two phases, 0.3 s then 0.4 s, half a viewport short", () => {
    expect(planJump(0, 1201, 600)).toEqual([
      { to: 901, duration: 300, easing: "easeIn" },
      { to: 1201, duration: 400, easing: "easeOut" },
    ])
    expect(planJump(5000, 1000, 600)).toEqual([
      { to: 1300, duration: 300, easing: "easeIn" },
      { to: 1000, duration: 400, easing: "easeOut" },
    ])
  })

  it("does nothing when already there", () => {
    expect(planJump(100, 100.3, 600)).toEqual([])
  })

  it("lands from the side the reader comes from", () => {
    expect(planLanding(1000, 600, "up")).toEqual({ from: 1300, phase: { to: 1000, duration: 400, easing: "easeOut" } })
    expect(planLanding(1000, 600, "down").from).toBe(700)
  })

  it("eases monotonically from 0 to 1", () => {
    for (const easing of ["easeIn", "easeOut", "easeInOut", "linear"] as const) {
      expect(ease(easing, 0)).toBe(0)
      expect(ease(easing, 1)).toBe(1)
      let last = 0
      for (let t = 0.05; t < 1; t += 0.05) {
        const value = ease(easing, t)
        expect(value).toBeGreaterThanOrEqual(last)
        last = value
      }
    }
    expect(ease("easeIn", 0.5)).toBeLessThan(0.5)
    expect(ease("easeOut", 0.5)).toBeGreaterThan(0.5)
    expect(ease("easeInOut", 0.5)).toBeCloseTo(0.5, 5)
  })
})

describe("read marking (rule 4)", () => {
  const ready: ReadInput = {
    appActive: true,
    windowVisible: true,
    placed: true,
    withinFollowZone: false,
    atLiveEnd: false,
    newestMessageId: mid(100),
    highestVisibleIncoming: mid(60),
    contiguousThrough: mid(100),
    readFrontier: mid(40),
  }

  it.each<[string, Partial<ReadInput>, ReturnType<typeof decideRead>]>([
    ["app inactive", { appActive: false }, { kind: "none" }],
    ["window hidden", { windowVisible: false }, { kind: "none" }],
    ["not landed yet", { placed: false }, { kind: "none" }],
    ["live end inside the follow zone: read all", { withinFollowZone: true, atLiveEnd: true }, { kind: "readAll", maxId: mid(100) }],
    ["follow zone but window not at the live end: visible only", { withinFollowZone: true }, { kind: "readUpTo", maxId: mid(60) }],
    ["live end outside the follow zone: visible only", { atLiveEnd: true }, { kind: "readUpTo", maxId: mid(60) }],
    ["in history: up to the highest visible incoming", {}, { kind: "readUpTo", maxId: mid(60) }],
    ["never across an uncertified hole", { contiguousThrough: mid(50) }, { kind: "readUpTo", maxId: mid(50) }],
    ["nothing certified: nothing", { contiguousThrough: undefined }, { kind: "none" }],
    ["no incoming message visible", { highestVisibleIncoming: undefined }, { kind: "none" }],
    ["never backwards", { readFrontier: mid(60) }, { kind: "none" }],
    ["read all only when ahead", { withinFollowZone: true, atLiveEnd: true, readFrontier: mid(100) }, { kind: "none" }],
    ["nothing read yet", { readFrontier: undefined }, { kind: "readUpTo", maxId: mid(60) }],
  ])("%s", (_name, change, expected) => {
    const input = { ...ready, ...change } as ReadInput
    for (const key of Object.keys(change) as (keyof ReadInput)[]) if (change[key] === undefined) delete input[key]
    expect(decideRead(input)).toEqual(expected)
  })
})

describe("jump to latest count (rule 5, Mac ChatUnreadBadgeCount)", () => {
  const rows = [msg(10), msg(11), msg(12, { from: ME }), msg(13), msg(14)]

  it("is the server's count when nothing is pending", () => {
    expect(jumpToLatestCount({ unreadCount: 4, readMaxId: mid(10), rows, viewerId: ME })).toBe(4)
    expect(jumpToLatestCount({ unreadCount: 4, readMaxId: mid(10), readFrontier: mid(10), rows, viewerId: ME })).toBe(4)
  })

  it("subtracts incoming messages read locally that the server has not counted yet", () => {
    // 11 and 13 are incoming and between the server's marker and the local frontier; 12 is own.
    expect(
      jumpToLatestCount({ unreadCount: 4, readMaxId: mid(10), readFrontier: mid(13), contiguousThrough: mid(14), rows, viewerId: ME }),
    ).toBe(2)
  })

  it("subtracts nothing past contiguous history and never goes negative", () => {
    expect(
      jumpToLatestCount({ unreadCount: 4, readMaxId: mid(10), readFrontier: mid(13), contiguousThrough: mid(11), rows, viewerId: ME }),
    ).toBe(3)
    expect(
      jumpToLatestCount({ unreadCount: 1, readMaxId: mid(10), readFrontier: mid(14), contiguousThrough: mid(14), rows, viewerId: ME }),
    ).toBe(0)
  })

  it("is zero when the server says so", () => {
    expect(jumpToLatestCount({ unreadCount: 0, readMaxId: messageId(0), readFrontier: mid(14), rows, viewerId: ALICE })).toBe(0)
  })
})

describe("compensation sums", () => {
  it("sums only the changes above the anchor, ignoring zero sizes and keeping the cache", () => {
    const order = indexKeys(["a", "b", "c", "d"])
    const sizes = new Map([
      ["a", 10],
      ["b", 20],
      ["c", 30],
      ["d", 40],
    ])
    expect(resizeDelta([{ key: "a", height: 15 }, { key: "b", height: 0 }, { key: "d", height: 50 }], order, "c", sizes)).toBe(5)
    expect(sizes.get("b")).toBe(20)
    expect(sizes.get("d")).toBe(50)
    expect(resizeDelta([{ key: "a", height: 15 }], order, "c", sizes)).toBe(0)
  })

  it("adds inserted rows above the anchor and subtracts removed ones", () => {
    const before = ["a", "b", "c"]
    const after = ["x", "y", "b", "c", "z"]
    const sizes = new Map([
      ["a", 10],
      ["b", 20],
      ["c", 30],
      ["x", 7],
      ["y", 8],
      ["z", 9],
    ])
    expect(structuralDelta(before, indexKeys(before), after, indexKeys(after), "c", sizes)).toBe(7 + 8 - 10)
  })

  it("counts a row moving across the anchor", () => {
    const before = ["a", "b", "c"]
    const after = ["b", "c", "a"]
    const sizes = new Map([
      ["a", 10],
      ["b", 20],
      ["c", 30],
    ])
    expect(structuralDelta(before, indexKeys(before), after, indexKeys(after), "c", sizes)).toBe(-10)
  })
})
