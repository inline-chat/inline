import { createManualClock } from "@inline/ui"
import { describe, expect, it } from "vitest"
import { findTitleMatch, TitleTypeahead } from "./typeahead"

const titles = ["Ada Lovelace", "Alan Turing", "Brand refresh", "Émile Zola", "ليلى حسن", "Alice", "王芳"]
const titleAt = (index: number) => titles[index]

describe("findTitleMatch", () => {
  it("searches from the item after the current one and wraps", () => {
    expect(findTitleMatch(titles.length, titleAt, "a", -1)).toBe(0)
    expect(findTitleMatch(titles.length, titleAt, "a", 0)).toBe(1)
    expect(findTitleMatch(titles.length, titleAt, "a", 5)).toBe(0)
  })

  it("keeps the current item while a growing query still matches", () => {
    expect(findTitleMatch(titles.length, titleAt, "al", 1)).toBe(1)
    expect(findTitleMatch(titles.length, titleAt, "ali", 1)).toBe(5)
  })

  it("cycles on a repeated character", () => {
    expect(findTitleMatch(titles.length, titleAt, "aa", 0)).toBe(1)
  })

  it("ignores case and accents, and matches any script", () => {
    expect(findTitleMatch(titles.length, titleAt, "emi", -1)).toBe(3)
    expect(findTitleMatch(titles.length, titleAt, "لي", -1)).toBe(4)
    expect(findTitleMatch(titles.length, titleAt, "王", -1)).toBe(6)
  })

  it("returns -1 without a match, and skips unloaded titles", () => {
    expect(findTitleMatch(titles.length, titleAt, "zz", -1)).toBe(-1)
    expect(findTitleMatch(3, (i) => (i === 1 ? undefined : "x"), "x", 0)).toBe(2)
  })

  it("reads titles lazily, from the current position", () => {
    const read: number[] = []
    const many = (index: number) => {
      read.push(index)
      return index === 1003 ? "Target" : "Other"
    }
    expect(findTitleMatch(5000, many, "t", 1000)).toBe(1003)
    expect(read).toEqual([1001, 1002, 1003])
  })
})

describe("TitleTypeahead", () => {
  it("builds a query until a pause clears it", () => {
    const clock = createManualClock()
    const typeahead = new TitleTypeahead({ clock, timeout: 500 })
    expect(typeahead.type("a", titles.length, titleAt, -1)).toBe(0)
    expect(typeahead.active).toBe(true)
    expect(typeahead.type("l", titles.length, titleAt, 0)).toBe(1)
    expect(typeahead.buffer).toBe("al")
    clock.advance(500)
    expect(typeahead.active).toBe(false)
    expect(typeahead.type("b", titles.length, titleAt, 1)).toBe(2)
    typeahead.reset()
    expect(typeahead.buffer).toBe("")
  })
})
