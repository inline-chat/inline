import type { TimelineWindow } from "@inline/timeline"
import { describe, expect, it } from "vitest"
import { isEmpty, newerEdge, olderEdge, type EdgeInput } from "./chrome"

const LIVE: TimelineWindow = { hasOlder: true, hasNewer: false, atLatest: true, loading: "none" }

const input = (overrides: Partial<EdgeInput> = {}): EdgeInput => ({
  window: LIVE,
  range: { start: 0, end: 50 },
  length: 50,
  hidden: false,
  ...overrides,
})

describe("olderEdge", () => {
  it("loading wins while the core loads an older page", () => {
    expect(olderEdge(input({ window: { ...LIVE, loading: "older" } }))).toBe("loading")
  })

  it("more while older rows exist, loaded or not", () => {
    expect(olderEdge(input())).toBe("more")
    expect(olderEdge(input({ window: { ...LIVE, hasOlder: false }, range: { start: 10, end: 50 } }))).toBe("more")
  })

  it("start at the beginning of the conversation, and without a window", () => {
    expect(olderEdge(input({ window: { ...LIVE, hasOlder: false } }))).toBe("start")
    expect(olderEdge(input({ window: undefined }))).toBe("start")
  })
})

describe("newerEdge", () => {
  it("none when the rendered rows reach the live end", () => {
    expect(newerEdge(input())).toBe("none")
    expect(newerEdge(input({ window: undefined }))).toBe("none")
  })

  it("more when rows below are loaded but not rendered, or the window stops short of latest", () => {
    expect(newerEdge(input({ range: { start: 0, end: 40 } }))).toBe("more")
    expect(newerEdge(input({ window: { ...LIVE, atLatest: false, hasNewer: true } }))).toBe("more")
  })

  it("loading while the core loads a newer page", () => {
    expect(newerEdge(input({ window: { ...LIVE, atLatest: false, hasNewer: true, loading: "newer" } }))).toBe("loading")
  })
})

describe("isEmpty", () => {
  it("only for a chat with no messages that is neither loading nor hidden", () => {
    expect(isEmpty(input({ length: 0, range: { start: 0, end: 0 } }))).toBe(true)
    expect(isEmpty(input({ length: 0, range: { start: 0, end: 0 }, window: { ...LIVE, loading: "initial" } }))).toBe(false)
    expect(isEmpty(input({ length: 0, range: { start: 0, end: 0 }, hidden: true }))).toBe(false)
    expect(isEmpty(input())).toBe(false)
  })
})
