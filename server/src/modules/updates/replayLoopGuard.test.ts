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

  test("resets rewind backoff after passing the previous high-water mark on the same socket", () => {
    let now = 0
    const guard = new ReplayLoopGuard(() => now)
    for (const seq of [4000, 0, 4000]) expect(guard.allow("a", seq)).toBe(true)
    expect(guard.allow("a", 0)).toBe(false)

    // Recovery is possible during backoff, without an idle expiry or reconnect.
    expect(guard.allow("a", 4001)).toBe(true)
    now += 1000
    expect(guard.allow("a", 0)).toBe(true)
    expect(guard.allow("a", 4001)).toBe(true)
    expect(guard.allow("a", 0)).toBe(false)
    // A new failure episode starts at 60 seconds, not the old 120-second step.
    now += 59_999
    expect(guard.allow("a", 0)).toBe(false)
    now += 1
    expect(guard.allow("a", 0)).toBe(true)
  })
})

describe("replay loop guard: repeated identical pages", () => {
  test("empty polls and page retries stay free; a third identical non-empty fetch is slowed with growing windows", () => {
    let now = 0
    const guard = new ReplayLoopGuard(() => now)
    // Polling an empty frontier never counts.
    for (let i = 0; i < 50; i++) {
      expect(guard.allow("s", 4000)).toBe(true)
      guard.served("s", 4000, 0)
    }
    // A client that cannot apply the first page keeps asking for it.
    expect(guard.allow("s", 0)).toBe(true)
    guard.served("s", 0, 100)
    expect(guard.allow("s", 0)).toBe(true)
    guard.served("s", 0, 100)
    expect(guard.allow("s", 0)).toBe(true)
    guard.served("s", 0, 100)
    expect(guard.allow("s", 0)).toBe(false)
    now = 59_999
    expect(guard.allow("s", 0)).toBe(false)
    now = 60_000
    expect(guard.allow("s", 0)).toBe(true)
    guard.served("s", 0, 100)
    expect(guard.allow("s", 0)).toBe(false)
    now += 119_999
    expect(guard.allow("s", 0)).toBe(false)
    now += 1
    expect(guard.allow("s", 0)).toBe(true)
    guard.served("s", 0, 100)
    expect(guard.allow("s", 0)).toBe(false)
    // Windows keep doubling to the cap and stay there. The stuck client keeps
    // polling while blocked, so the idle expiry never gives it a clean slate.
    for (const windowMs of [240_000, 480_000, 960_000, 1_800_000, 1_800_000]) {
      const windowEnd = now + windowMs
      while (now + 300_000 < windowEnd) {
        now += 300_000
        expect(guard.allow("s", 0)).toBe(false)
      }
      now = windowEnd - 1
      expect(guard.allow("s", 0)).toBe(false)
      now += 1
      expect(guard.allow("s", 0)).toBe(true)
      guard.served("s", 0, 100)
      expect(guard.allow("s", 0)).toBe(false)
    }
  })

  test("forward progress or a different start resets the repeat count without a reconnect", () => {
    const guard = new ReplayLoopGuard()
    expect(guard.allow("s", 0)).toBe(true)
    guard.served("s", 0, 100)
    expect(guard.allow("s", 0)).toBe(true)
    guard.served("s", 0, 100)
    expect(guard.allow("s", 100)).toBe(true)
    guard.served("s", 100, 100)
    expect(guard.allow("s", 100)).toBe(true)
    guard.served("s", 100, 100)
    expect(guard.allow("s", 100)).toBe(true)
    guard.served("s", 100, 100)
    expect(guard.allow("s", 100)).toBe(false)
    expect(guard.allow("s", 200)).toBe(true)
    guard.served("s", 200, 100)
    expect(guard.allow("s", 200)).toBe(true)
  })

  test("served records for another start do not count against the current one", () => {
    const guard = new ReplayLoopGuard()
    expect(guard.allow("s", 0)).toBe(true)
    guard.served("s", 5, 100)
    for (let i = 0; i < 5; i++) expect(guard.allow("s", 0)).toBe(true)
  })
})
