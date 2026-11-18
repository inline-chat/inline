import { describe, expect, it } from "vitest"
import { AFTER_PAINT_FALLBACK_MS, createAfterPaint } from "./perf"

const env = (options: { frames: boolean; hidden?: boolean }) => {
  const timers: { fn: () => void; ms: number }[] = []
  const frames: (() => void)[] = []
  return {
    timers,
    frames,
    afterPaint: createAfterPaint({
      ...(options.frames ? { requestAnimationFrame: (cb: () => void) => frames.push(cb) } : {}),
      setTimeout: (fn, ms) => timers.push({ fn, ms }),
      isHidden: () => options.hidden === true,
    }),
    runTimers: (upTo: number) => {
      for (const timer of timers.splice(0).filter((t) => t.ms <= upTo)) timer.fn()
    },
  }
}

describe("after paint", () => {
  it("runs a task after the frame when the page is painted", () => {
    const e = env({ frames: true })
    let runs = 0
    e.afterPaint(() => runs++)
    expect(runs).toBe(0)
    e.frames.shift()!()
    expect(runs).toBe(0)
    e.runTimers(0)
    expect(runs).toBe(1)
  })

  it("runs anyway when no frame comes (a covered window, a pane that is not shown), once", () => {
    const e = env({ frames: true })
    let runs = 0
    e.afterPaint(() => runs++)
    e.runTimers(AFTER_PAINT_FALLBACK_MS)
    expect(runs).toBe(1)
    // The frame arriving late does not run it again.
    e.frames.shift()!()
    e.runTimers(0)
    expect(runs).toBe(1)
  })

  it("does not wait for a frame in a hidden tab", () => {
    const e = env({ frames: true, hidden: true })
    let runs = 0
    e.afterPaint(() => runs++)
    expect(e.frames).toHaveLength(0)
    e.runTimers(0)
    expect(runs).toBe(1)
  })

  it("falls back to a task without animation frames", () => {
    const e = env({ frames: false })
    let runs = 0
    e.afterPaint(() => runs++)
    e.runTimers(0)
    expect(runs).toBe(1)
  })
})
