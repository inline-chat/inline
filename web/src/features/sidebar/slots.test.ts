import type { RowKey } from "@inline/core-protocol"
import { describe, expect, it } from "vitest"
import { assignSlots, enteringKeys } from "./slots"

const k = (...ns: number[]) => ns.map((n) => `dialog:${n}` as RowKey)

describe("assignSlots", () => {
  it("fills slots in window order the first time", () => {
    expect(assignSlots([], k(1, 2, 3))).toEqual(k(1, 2, 3))
  })

  it("keeps every staying key in its slot; entering keys take freed slots", () => {
    const first = assignSlots([], k(1, 2, 3, 4))
    // Scrolled down by two rows: 1 and 2 leave, 5 and 6 enter.
    expect(assignSlots(first, k(3, 4, 5, 6))).toEqual(k(5, 6, 3, 4))
  })

  it("returns the same array for a reorder inside the window", () => {
    const first = assignSlots([], k(1, 2, 3, 4))
    expect(assignSlots(first, k(4, 3, 2, 1))).toBe(first)
  })

  it("grows for a larger window and keeps a few spare empty slots", () => {
    const first = assignSlots([], k(1, 2, 3))
    const grown = assignSlots(first, k(1, 2, 3, 4, 5))
    expect(grown).toEqual(k(1, 2, 3, 4, 5))
    const shrunk = assignSlots(grown, k(2))
    expect(shrunk).toEqual([undefined, ...k(2), undefined, undefined, undefined])
  })

  it("drops trailing spares only far beyond the window", () => {
    const big = assignSlots([], k(...Array.from({ length: 40 }, (_, i) => i)))
    const small = assignSlots(big, k(0, 1), 4)
    expect(small).toEqual(k(0, 1))
  })

  it("names the keys a new assignment shows that the old did not", () => {
    const first = assignSlots([], k(1, 2, 3))
    expect(enteringKeys(first, assignSlots(first, k(2, 3, 4)))).toEqual(k(4))
    expect(enteringKeys(first, first)).toEqual([])
  })
})
