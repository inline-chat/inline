import { describe, expect, test } from "bun:test"
import { ReplayLoopGuard } from "./replayLoopGuard"

describe("replay loop guard", () => {
  test("allows cold catch-up, page retries, empty polls, and one full retry", () => {
    const guard = new ReplayLoopGuard()
    for (let seq = 0; seq <= 4000; seq += 100) expect(guard.allow("a", seq)).toBe(true)
    for (let i = 0; i < 100; i++) expect(guard.allow("a", 4000)).toBe(true)
    expect(guard.allow("a", 3900)).toBe(true)
    expect(guard.allow("a", 0)).toBe(true)
    for (let seq = 100; seq <= 4000; seq += 100) expect(guard.allow("a", seq)).toBe(true)
  })

  test("slows repeated large rewinds with bounded retry windows and no cursor changes", () => {
    let now = 0
    const guard = new ReplayLoopGuard(() => now)
    expect(guard.allow("a", 4000)).toBe(true)
    expect(guard.allow("a", 0)).toBe(true)
    expect(guard.allow("a", 4000)).toBe(true)
    expect(guard.allow("a", 0)).toBe(false)
    now = 59_999
    expect(guard.allow("a", 0)).toBe(false)
    now = 60_000
    expect(guard.allow("a", 0)).toBe(true)
    expect(guard.allow("a", 4000)).toBe(true)
    expect(guard.allow("a", 0)).toBe(false)
    now += 119_999
    expect(guard.allow("a", 0)).toBe(false)
    now += 1
    expect(guard.allow("a", 0)).toBe(true)
    for (let cycle = 0; cycle < 6; cycle++) {
      expect(guard.allow("a", 4000)).toBe(true)
      expect(guard.allow("a", 0)).toBe(false)
      now += 300_000
      expect(guard.allow("a", 0)).toBe(true)
    }
  })

  test("isolates sockets and permits recovered forward progress during backoff", () => {
    const guard = new ReplayLoopGuard()
    for (const seq of [4000, 0, 4000]) expect(guard.allow("a", seq)).toBe(true)
    expect(guard.allow("a", 0)).toBe(false)
    expect(guard.allow("b", 0)).toBe(true)
    expect(guard.allow("a", 4001)).toBe(true)
    expect(guard.allow("a", 4100)).toBe(true)
  })

  test("idle expiry and LRU eviction permit recovery without unbounded identity retention", () => {
    let now = 0
    const guard = new ReplayLoopGuard(() => now, 2)
    for (const seq of [4000, 0, 4000]) guard.allow("a", seq)
    expect(guard.allow("a", 0)).toBe(false)
    now = 600_000
    expect(guard.allow("a", 4000)).toBe(true)
    expect(guard.allow("a", 0)).toBe(true)
    guard.allow("b", 0)
    guard.allow("c", 0)
    expect(guard.allow("a", 4000)).toBe(true)
    expect(guard.allow("a", 0)).toBe(true)
  })
})
