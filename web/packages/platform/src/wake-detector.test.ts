import { describe, expect, it } from "vitest"
import { createUpdateFeed } from "./update-feed"
import { userGesture, isUserGesture } from "./gesture"
import { createWakeDetector } from "./wake-detector"
import { manualClock } from "./testing/manual-clock"

describe("wake detector", () => {
  const setup = () => {
    const clock = manualClock()
    const wakes: number[] = []
    const detector = createWakeDetector({ clock, onWake: (gap) => wakes.push(gap) })
    return { clock, wakes, detector }
  }

  it("stays quiet while timers run on time", () => {
    const { clock, wakes } = setup()
    clock.advance(10 * 60_000)
    expect(wakes).toEqual([])
  })

  it("stays quiet through one-minute throttling of a hidden tab", () => {
    const { clock, wakes, detector } = setup()
    // A throttled tab: the 10 s timer runs at the next minute boundary.
    clock.sleep(60_000)
    clock.sleep(60_000)
    detector.check()
    expect(wakes).toEqual([])
  })

  it("reports a sleep longer than interval plus tolerance, once", () => {
    const { clock, wakes } = setup()
    clock.advance(5_000)
    clock.sleep(30 * 60_000)
    expect(wakes).toEqual([30 * 60_000 + 5_000])
    clock.advance(60_000)
    expect(wakes).toHaveLength(1)
  })

  it("check() notices a wake before the next tick", () => {
    // A clock whose timers never fire, as when the page regains focus right
    // after waking and before the delayed timer runs.
    let now = 0
    const clock = { now: () => now, setTimeout: () => 1, clearTimeout: () => {} }
    const wakes: number[] = []
    const detector = createWakeDetector({ clock, onWake: (gap) => wakes.push(gap) })
    now += 20_000
    detector.check()
    expect(wakes).toEqual([])
    now += 5 * 60_000
    detector.check()
    expect(wakes).toEqual([5 * 60_000])
  })

  it("dispose stops the timer", () => {
    const { clock, wakes, detector } = setup()
    detector.dispose()
    expect(clock.pendingTimers()).toBe(0)
    clock.sleep(60 * 60_000)
    detector.check()
    expect(wakes).toEqual([])
  })
})

describe("user gesture tokens", () => {
  it("are minted only for trusted activating events", () => {
    expect(userGesture({ isTrusted: true, type: "click" })).not.toBeNull()
    expect(userGesture({ isTrusted: true, type: "keydown" })).not.toBeNull()
    expect(userGesture({ isTrusted: false, type: "click" })).toBeNull()
    expect(userGesture({ isTrusted: true, type: "mousemove" })).toBeNull()
    expect(userGesture({ isTrusted: true, type: "focus" })).toBeNull()
  })

  it("cannot be forged", () => {
    expect(isUserGesture({ eventType: "click" })).toBe(false)
    expect(isUserGesture(userGesture({ isTrusted: true, type: "click" }))).toBe(true)
  })
})

describe("update feed", () => {
  it("holds the state and applies only when ready", () => {
    const { updater, feed } = createUpdateFeed()
    let applied = 0
    feed.setApplyHandler(() => applied++)
    expect(updater.state.get()).toEqual({ status: "none" })
    feed.report({ status: "available", version: "2" })
    updater.apply()
    expect(applied).toBe(0)
    feed.report({ status: "ready", version: "2" })
    expect(updater.state.get()).toEqual({ status: "ready", version: "2" })
    updater.apply()
    expect(applied).toBe(1)
    feed.setApplyHandler(null)
    updater.apply()
    expect(applied).toBe(1)
  })
})
