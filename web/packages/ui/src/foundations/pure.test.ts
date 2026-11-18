import { describe, expect, test } from "vitest"
import { createManualClock, Timer } from "./clock"
import { navigate } from "./collection"
import { HoverIntent, isPointInPolygon, safePolygon } from "./hover-intent"
import { childId, createId } from "./id"
import { hasCommandModifier } from "./platform"
import { findTypeaheadMatch, Typeahead } from "./typeahead"

describe("manual clock", () => {
  test("runs due timers in order and only when advanced", () => {
    const clock = createManualClock()
    const order: string[] = []
    clock.setTimeout(() => order.push("b"), 20)
    clock.setTimeout(() => order.push("a"), 10)
    const cancelled = clock.setTimeout(() => order.push("x"), 15)
    clock.clearTimeout(cancelled)
    clock.advance(9)
    expect(order).toEqual([])
    clock.advance(11)
    expect(order).toEqual(["a", "b"])
    expect(clock.now()).toBe(20)
    expect(clock.pending()).toBe(0)
  })

  test("a timer restarted inside advance runs at its new time", () => {
    const clock = createManualClock()
    const timer = new Timer(clock)
    let fired = 0
    timer.start(10, () => fired++)
    clock.advance(5)
    timer.start(10, () => fired++)
    clock.advance(9)
    expect(fired).toBe(0)
    clock.advance(1)
    expect(fired).toBe(1)
    expect(timer.running).toBe(false)
  })
})

describe("ids", () => {
  test("are unique and child ids are attribute safe", () => {
    expect(createId("menu")).not.toBe(createId("menu"))
    expect(childId("in-lb-1", "a b/c")).toMatch(/^in-lb-1-a[\w-]+$/)
  })
})

describe("collection navigation", () => {
  const items = [{ id: "a" }, { id: "b", disabled: true }, { id: "c" }, { id: "d" }]

  test("moves and skips disabled items", () => {
    expect(navigate(items, "a", "next")).toBe("c")
    expect(navigate(items, "c", "prev")).toBe("a")
    expect(navigate(items, null, "next")).toBe("a")
    expect(navigate(items, null, "prev")).toBe("d")
    expect(navigate(items, "c", "first")).toBe("a")
    expect(navigate(items, "a", "last")).toBe("d")
  })

  test("stops at the ends unless looping", () => {
    expect(navigate(items, "d", "next")).toBe("d")
    expect(navigate(items, "d", "next", { loop: true })).toBe("a")
    expect(navigate(items, "a", "prev", { loop: true })).toBe("d")
  })

  test("pages by pageSize", () => {
    const many = Array.from({ length: 30 }, (_, index) => ({ id: String(index) }))
    expect(navigate(many, "0", "pageDown", { pageSize: 10 })).toBe("10")
    expect(navigate(many, "25", "pageDown", { pageSize: 10 })).toBe("29")
    expect(navigate(many, "5", "pageUp", { pageSize: 10 })).toBe("0")
  })

  test("returns null for an empty or fully disabled collection", () => {
    expect(navigate([], null, "next")).toBeNull()
    expect(navigate([{ id: "x", disabled: true }], null, "first")).toBeNull()
  })
})

describe("typeahead", () => {
  const items = [
    { id: "apple", text: "Apple" },
    { id: "apricot", text: "Apricot" },
    { id: "banana", text: "Banana" },
    { id: "blue", text: "Blueberry", disabled: true },
    { id: "eclair", text: "Éclair" },
  ]

  test("finds by prefix, case and accent insensitive", () => {
    expect(findTypeaheadMatch(items, "b", null)).toBe("banana")
    expect(findTypeaheadMatch(items, "e", null)).toBe("eclair")
    expect(findTypeaheadMatch(items, "apr", "apple")).toBe("apricot")
    expect(findTypeaheadMatch(items, "z", null)).toBeNull()
  })

  test("a repeated character cycles through matches after the current item", () => {
    expect(findTypeaheadMatch(items, "a", "apple")).toBe("apricot")
    expect(findTypeaheadMatch(items, "aa", "apricot")).toBe("apple")
  })

  test("skips disabled items", () => {
    expect(findTypeaheadMatch(items, "bl", null)).toBeNull()
  })

  test("the buffer accumulates and clears after the timeout", () => {
    const clock = createManualClock()
    const typeahead = new Typeahead({ clock, timeout: 500 })
    expect(typeahead.type("a", items, null)).toBe("apple")
    expect(typeahead.type("p", items, "apple")).toBe("apple")
    expect(typeahead.type("r", items, "apple")).toBe("apricot")
    expect(typeahead.active).toBe(true)
    clock.advance(500)
    expect(typeahead.active).toBe(false)
    expect(typeahead.type("b", items, "apricot")).toBe("banana")
  })
})

describe("hover intent", () => {
  const submenu = { x: 200, y: 50, width: 150, height: 200 }

  test("point in polygon", () => {
    const square = [
      { x: 0, y: 0 },
      { x: 10, y: 0 },
      { x: 10, y: 10 },
      { x: 0, y: 10 },
    ]
    expect(isPointInPolygon({ x: 5, y: 5 }, square)).toBe(true)
    expect(isPointInPolygon({ x: 15, y: 5 }, square)).toBe(false)
  })

  test("the safe polygon covers the path to the submenu, not beside it", () => {
    const polygon = safePolygon({ x: 190, y: 100 }, submenu)
    expect(isPointInPolygon({ x: 195, y: 110 }, polygon)).toBe(true)
    expect(isPointInPolygon({ x: 199, y: 220 }, polygon)).toBe(true)
    expect(isPointInPolygon({ x: 150, y: 140 }, polygon)).toBe(false)
  })

  test("the polygon mirrors when the submenu is on the left (right to left)", () => {
    const left = { x: 0, y: 50, width: 150, height: 200 }
    const polygon = safePolygon({ x: 160, y: 100 }, left)
    expect(isPointInPolygon({ x: 152, y: 120 }, polygon)).toBe(true)
    expect(isPointInPolygon({ x: 200, y: 120 }, polygon)).toBe(false)
  })

  test("intent lasts while moving inside, ends on leaving, and expires after the grace period", () => {
    const clock = createManualClock()
    let expired = 0
    const intent = new HoverIntent({ clock, grace: 300, onExpire: () => expired++ })
    intent.begin({ x: 190, y: 100 }, submenu)
    expect(intent.isInTransit({ x: 194, y: 104 })).toBe(true)
    clock.advance(250)
    expect(intent.isInTransit({ x: 196, y: 108 })).toBe(true)
    clock.advance(250)
    expect(intent.active).toBe(true)
    clock.advance(60)
    expect(intent.active).toBe(false)
    expect(expired).toBe(1)

    intent.begin({ x: 190, y: 100 }, submenu)
    expect(intent.isInTransit({ x: 100, y: 100 })).toBe(false)
    expect(intent.active).toBe(false)
  })
})

describe("platform modifier", () => {
  test("is Cmd on Mac and Ctrl elsewhere", () => {
    expect(hasCommandModifier({ metaKey: true }, "mac")).toBe(true)
    expect(hasCommandModifier({ ctrlKey: true }, "mac")).toBe(false)
    expect(hasCommandModifier({ ctrlKey: true }, "other")).toBe(true)
    expect(hasCommandModifier({ metaKey: true }, "other")).toBe(false)
  })
})
