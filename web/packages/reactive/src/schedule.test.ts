import { describe, expect, it } from "vitest"
import { browserScheduler, createScheduler, manualTime } from "./schedule"
import { effect, signal } from "./signals"

describe("sync lane", () => {
  it("runs now, in one batch, and returns the value", () => {
    const time = manualTime()
    const scheduler = createScheduler({ clock: time, frames: time.frames })
    const a = signal(0)
    const b = signal(0)
    const seen: string[] = []
    effect(() => {
      seen.push(`${a.get()}${b.get()}`)
    })
    const result = scheduler.sync(() => {
      a.set(1)
      b.set(1)
      return "done"
    })
    expect(result).toBe("done")
    expect(seen).toEqual(["00", "11"])
  })
})

describe("frame lane", () => {
  it("coalesces everything queued before a frame into one batch at the frame", () => {
    const time = manualTime()
    const scheduler = createScheduler({ clock: time, frames: time.frames })
    const value = signal(0)
    const seen: number[] = []
    effect(() => {
      seen.push(value.get())
    })
    scheduler.frame(() => value.set(1))
    scheduler.frame(() => value.set(2))
    scheduler.frame(() => value.set(3))
    expect(seen).toEqual([0])
    expect(time.pendingFrames()).toBe(1)
    time.frame()
    expect(seen).toEqual([0, 3])
    // The safety timer was cancelled with the frame.
    expect(time.pendingTimers()).toBe(0)
  })

  it("runs work queued during a flush in the same flush", () => {
    const time = manualTime()
    const scheduler = createScheduler({ clock: time, frames: time.frames })
    const log: string[] = []
    scheduler.frame(() => {
      log.push("first")
      scheduler.frame(() => log.push("queued while flushing"))
    })
    time.frame()
    expect(log).toEqual(["first", "queued while flushing"])
    expect(time.pendingFrames()).toBe(0)
  })

  it("runs work that an end-of-batch effect queued in the next frame, not never", () => {
    const time = manualTime()
    const scheduler = createScheduler({ clock: time, frames: time.frames })
    const source = signal(0)
    const seen: string[] = []
    // The effect runs when the frame's batch ends, after the queue was emptied.
    const stop = effect(() => {
      if (source.get() === 1) scheduler.frame(() => seen.push("queued by an effect"))
    })
    scheduler.frame(() => source.set(1))
    time.frame()
    expect(seen).toEqual([])
    time.frame()
    expect(seen).toEqual(["queued by an effect"])
    stop()
  })

  it("falls back to a timer when there is no frame source", () => {
    const time = manualTime()
    const scheduler = createScheduler({ clock: time })
    const log: number[] = []
    scheduler.frame(() => log.push(1))
    scheduler.frame(() => log.push(2))
    time.advance(15)
    expect(log).toEqual([])
    time.advance(1)
    expect(log).toEqual([1, 2])
  })

  it("uses the timer while the page is hidden", () => {
    const time = manualTime()
    let hidden = true
    const scheduler = createScheduler({ clock: time, frames: time.frames, isHidden: () => hidden })
    const log: number[] = []
    scheduler.frame(() => log.push(1))
    expect(time.pendingFrames()).toBe(0)
    time.advance(16)
    expect(log).toEqual([1])
    hidden = false
    scheduler.frame(() => log.push(2))
    expect(time.pendingFrames()).toBe(1)
  })

  it("runs the frame on the safety timer if frames stop after the request", () => {
    const time = manualTime()
    const scheduler = createScheduler({ clock: time, frames: time.frames })
    const log: number[] = []
    scheduler.frame(() => log.push(1))
    time.advance(100)
    expect(log).toEqual([1])
    // The frame that never came is cancelled, so it cannot run twice.
    expect(time.pendingFrames()).toBe(0)
  })

  it("keeps running the queue when one item throws, and reports the error", () => {
    const time = manualTime()
    const errors: unknown[] = []
    const scheduler = createScheduler({ clock: time, frames: time.frames, onError: (e) => errors.push(e) })
    const log: number[] = []
    scheduler.frame(() => {
      throw new Error("bad patch")
    })
    scheduler.frame(() => log.push(2))
    time.frame()
    expect(log).toEqual([2])
    expect(errors).toHaveLength(1)
  })

  it("flushes on demand", () => {
    const time = manualTime()
    const scheduler = createScheduler({ clock: time, frames: time.frames })
    const log: number[] = []
    scheduler.frame(() => log.push(1))
    scheduler.flushFrame()
    expect(log).toEqual([1])
    expect(time.pendingFrames()).toBe(0)
  })
})

describe("idle lane", () => {
  it("runs tasks in idle slices and yields when the slice is used up", () => {
    const time = manualTime()
    const scheduler = createScheduler({ clock: time, idleSource: time.idleSource })
    let done = 0
    // Ten units of 3 ms each; a slice of 10 ms fits three.
    scheduler.idle((deadline) => {
      while (done < 10 && deadline.timeRemaining() > 0) {
        time.advance(3)
        done += 1
      }
      return done < 10
    })
    time.idle(10)
    expect(done).toBe(4)
    time.idle(10)
    expect(done).toBe(8)
    time.idle(10)
    expect(done).toBe(10)
    time.idle(10)
    expect(done).toBe(10)
  })

  it("runs one task when an idle callback fires on its timeout with no time left", () => {
    const time = manualTime()
    const scheduler = createScheduler({ clock: time, idleSource: time.idleSource })
    const ran: string[] = []
    scheduler.idle(() => void ran.push("a"))
    scheduler.idle(() => void ran.push("b"))
    // A busy page: the callback is forced by its timeout and reports zero time.
    time.idle(0)
    expect(ran).toEqual(["a"])
    time.idle(0)
    expect(ran).toEqual(["a", "b"])
  })

  it("lets other tasks run between the slices of a long task", () => {
    const time = manualTime()
    const scheduler = createScheduler({ clock: time, idleSource: time.idleSource })
    const log: string[] = []
    let slices = 0
    scheduler.idle(() => {
      slices += 1
      log.push(`long ${slices}`)
      return slices < 3
    })
    scheduler.idle(() => {
      log.push("short")
    })
    time.idle(100)
    time.idle(100)
    time.idle(100)
    expect(log).toEqual(["long 1", "short", "long 2", "long 3"])
  })

  it("falls back to timer slices without requestIdleCallback (Safari)", () => {
    const time = manualTime()
    const scheduler = createScheduler({ clock: time, idleSliceMs: 8, idleGapMs: 1 })
    let units = 0
    scheduler.idle((deadline) => {
      while (units < 6 && deadline.timeRemaining() > 0) {
        units += 1
        time.advance(4)
      }
      return units < 6
    })
    time.advance(1)
    expect(units).toBe(2)
    time.advance(1)
    expect(units).toBe(4)
    time.advance(1)
    expect(units).toBe(6)
    expect(time.pendingTimers()).toBe(0)
  })

  it("cancels queued idle work", () => {
    const time = manualTime()
    const scheduler = createScheduler({ clock: time, idleSource: time.idleSource })
    let ran = false
    const cancel = scheduler.idle(() => {
      ran = true
    })
    cancel()
    time.idle()
    expect(ran).toBe(false)
  })
})

describe("browserScheduler", () => {
  it("works in an environment with no frame or idle APIs (Node)", () => {
    const scheduler = browserScheduler()
    expect(scheduler.sync(() => 1)).toBe(1)
    let ran = false
    scheduler.frame(() => {
      ran = true
    })
    scheduler.flushFrame()
    expect(ran).toBe(true)
    scheduler.dispose()
  })
})
