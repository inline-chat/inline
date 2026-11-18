import { effect } from "@inline/reactive"
import { describe, expect, it } from "vitest"
import { FindHighlights, findOccurrences, normalizeRanges, sameRanges } from "./find"

describe("normalizeRanges", () => {
  it("clips to the text, drops empty and invalid ranges, sorts and merges", () => {
    expect(
      normalizeRanges(
        [
          [8, 12],
          [-3, 2],
          [5, 5],
          [10, 14],
          [14, 16],
          [Number.NaN, 3],
          [18, 40],
        ],
        20,
      ),
    ).toEqual([
      [0, 2],
      [8, 16],
      [18, 20],
    ])
  })

  it("is undefined when nothing remains", () => {
    expect(normalizeRanges([], 10)).toBeUndefined()
    expect(normalizeRanges([[12, 15]], 10)).toBeUndefined()
  })
})

describe("findOccurrences", () => {
  it("finds every case-insensitive occurrence in UTF-16 offsets", () => {
    expect(findOccurrences("Deploy the deploy 🚀 deploy", "DEPLOY")).toEqual([
      [0, 6],
      [11, 17],
      [21, 27],
    ])
    expect(findOccurrences("nothing here", "x")).toBeUndefined()
    expect(findOccurrences("text", "")).toBeUndefined()
  })
})

describe("FindHighlights", () => {
  it("gives ranges only to the rows that have them, through cached per-row signals", () => {
    const find = new FindHighlights()
    const a = find.rangesFor("7:1")
    const b = find.rangesFor("7:2")
    expect(find.rangesFor("7:1")).toBe(a)
    expect(a.peek()).toBeUndefined()

    find.showRow("7:1", [[0, 3]])
    expect(a.peek()).toEqual([[0, 3]])
    expect(b.peek()).toBeUndefined()
    expect(find.rows).toEqual(new Set(["7:1"]))

    find.show(new Map([["7:2", [[4, 6]] as const]]))
    expect(a.peek()).toBeUndefined()
    expect(b.peek()).toEqual([[4, 6]])

    find.clear()
    expect(b.peek()).toBeUndefined()
  })

  it("notifies only the rows whose ranges change when the active match moves", () => {
    const find = new FindHighlights()
    const runs = { a: 0, b: 0, c: 0 }
    const stops = (["a", "b", "c"] as const).map((key) =>
      effect(() => {
        find.rangesFor(`7:${key}`).get()
        runs[key] += 1
      }),
    )
    expect(runs).toEqual({ a: 1, b: 1, c: 1 })

    find.showRow("7:a", [[0, 2]])
    expect(runs).toEqual({ a: 2, b: 1, c: 1 })

    // The same ranges again, in a new array: nobody re-renders.
    find.showRow("7:a", [[0, 2]])
    expect(runs).toEqual({ a: 2, b: 1, c: 1 })

    // The active match moves from a to b: a and b change, c does not.
    find.showRow("7:b", [[1, 3]])
    expect(runs).toEqual({ a: 3, b: 2, c: 1 })
    for (const stop of stops) stop()
  })

  it("compares ranges by value", () => {
    expect(sameRanges(undefined, undefined)).toBe(true)
    expect(sameRanges([[0, 1]], [[0, 1]])).toBe(true)
    expect(sameRanges([[0, 1]], [[0, 2]])).toBe(false)
    expect(sameRanges([[0, 1]], undefined)).toBe(false)
  })
})
