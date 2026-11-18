import { describe, expect, it } from "vitest"
import { createFrameWaiter, FrameTimeoutError, WaitTimeoutError, type FrameScheduler } from "./frames"

/** A manual scheduler: frames and timers fire only when the test says so. */
const manual = () => {
  let now = 0
  let frames: ((now: number) => void)[] = []
  let timers: { at: number; fn: () => void }[] = []
  const scheduler: FrameScheduler = {
    requestFrame: (fn) => {
      frames.push(fn)
      return () => {
        frames = frames.filter((f) => f !== fn)
      }
    },
    setTimeout: (fn, ms) => {
      const timer = { at: now + ms, fn }
      timers.push(timer)
      return () => {
        timers = timers.filter((t) => t !== timer)
      }
    },
    now: () => now,
  }
  /** Let promise continuations run (a macrotask turn; no time passes on the manual clock). */
  const flush = () => new Promise<void>((resolve) => setTimeout(resolve, 0))
  return {
    scheduler,
    async frame() {
      now += 16
      const due = frames
      frames = []
      for (const fn of due) fn(now)
      await flush()
    },
    async advance(ms: number) {
      now += ms
      const due = timers.filter((t) => t.at <= now)
      timers = timers.filter((t) => t.at > now)
      for (const t of due) t.fn()
      await flush()
    },
  }
}

describe("frame waiter", () => {
  it("resolves on the next frame and cancels its timeout", async () => {
    const m = manual()
    const wait = createFrameWaiter(m.scheduler)
    const promise = wait.nextFrame()
    await m.frame()
    await expect(promise).resolves.toBe(16)
    await m.advance(10_000)
  })

  it("rejects with a clear error when frames stop", async () => {
    const m = manual()
    const wait = createFrameWaiter(m.scheduler)
    const promise = wait.nextFrame("Measuring prepend", 1000)
    const assertion = expect(promise).rejects.toThrow(FrameTimeoutError)
    await m.advance(1000)
    await assertion
    await expect(promise.catch((error: Error) => error.message)).resolves.toMatch(/^Measuring prepend: no animation frame for 1000 ms/)
  })

  it("frames(n) samples in each frame", async () => {
    const m = manual()
    const wait = createFrameWaiter(m.scheduler)
    const seen: number[] = []
    const done = wait.frames(3, (i) => seen.push(i))
    for (let i = 0; i < 3; i++) await m.frame()
    await done
    expect(seen).toEqual([0, 1, 2])
  })

  it("until() waits for the condition and gives up after both limits", async () => {
    const m = manual()
    const wait = createFrameWaiter(m.scheduler)
    let ready = false
    const reached = wait.until(() => ready, "ready")
    await m.frame()
    ready = true
    await m.frame()
    await expect(reached).resolves.toBe(2)

    const never = wait.until(() => false, "never", { maxFrames: 2, maxMs: 30 })
    const assertion = expect(never).rejects.toThrow(WaitTimeoutError)
    for (let i = 0; i < 2; i++) await m.frame()
    await assertion
  })
})
