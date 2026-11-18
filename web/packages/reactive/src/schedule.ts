/**
 * The three lanes. See web/docs/reactivity.md ("Scheduling").
 *
 * - sync: local echo of an intent. Runs now, in one batch, in the same task.
 * - frame: patches from the core. Everything queued before the next frame is
 *   applied in one batch at the start of that frame.
 * - idle: prefetch, warming, snapshots. Runs in slices while the main thread
 *   is idle and yields between slices.
 *
 * The clock, the frame source and the idle source are injected so tests are
 * deterministic; `browserScheduler` wires the real ones with fallbacks.
 */

import { batch } from "./signals"

export type TimerHandle = unknown

export interface Clock {
  /** Milliseconds, monotonic. */
  now(): number
  setTimeout(fn: () => void, ms: number): TimerHandle
  clearTimeout(handle: TimerHandle): void
}

export interface FrameSource {
  /** Request a callback before the next paint. */
  request(fn: () => void): TimerHandle
  cancel(handle: TimerHandle): void
}

export interface IdleDeadline {
  /** Milliseconds left in this idle slice. */
  timeRemaining(): number
}

export interface IdleSource {
  request(fn: (deadline: IdleDeadline) => void): TimerHandle
  cancel(handle: TimerHandle): void
}

/**
 * One slice of idle work. Return `true` to be called again in a later slice
 * (it yielded with work left), anything else when done. Check
 * `deadline.timeRemaining()` and return early when it reaches zero.
 */
export type IdleTask = (deadline: IdleDeadline) => boolean | void

export interface Scheduler {
  /** Run `fn` now inside one batch. For local echo of an intent. */
  sync<T>(fn: () => T): T
  /** Queue `fn` for the next frame; every queued function runs in one batch. */
  frame(fn: () => void): void
  /** Run everything queued for the frame lane now. Tests and teardown use it. */
  flushFrame(): void
  /** Queue idle work. Returns a cancel function. */
  idle(task: IdleTask): () => void
  /** Cancel pending frames and idle work. Queued work is dropped. */
  dispose(): void
}

export type SchedulerOptions = {
  clock: Clock
  /** Missing: the frame lane runs on a timer. */
  frames?: FrameSource
  /** Missing: the idle lane runs on short timer slices. */
  idleSource?: IdleSource
  /** When true at the time a frame is requested, use the timer, not the frame source. */
  isHidden?: () => boolean
  /** Delay of the timer used when there is no usable frame source. Default 16 ms. */
  frameFallbackMs?: number
  /**
   * When the frame source is used, a timer of this length runs the frame
   * anyway in case frames stop (the page was hidden after the request).
   * Default 100 ms.
   */
  frameSafetyMs?: number
  /** Length of an idle slice when there is no idle source. Default 8 ms. */
  idleSliceMs?: number
  /** Gap between fallback idle slices, so input can run. Default 1 ms. */
  idleGapMs?: number
  /** Where errors thrown by queued work go. Default: rethrown after the batch. */
  onError?: (error: unknown) => void
}

export const createScheduler = (options: SchedulerOptions): Scheduler => {
  const {
    clock,
    frames,
    idleSource,
    isHidden,
    frameFallbackMs = 16,
    frameSafetyMs = 100,
    idleSliceMs = 8,
    idleGapMs = 1,
  } = options
  const onError =
    options.onError ??
    ((error: unknown) => {
      clock.setTimeout(() => {
        throw error
      }, 0)
    })

  // Frame lane --------------------------------------------------------------

  let frameQueue: (() => void)[] = []
  let frameHandle: TimerHandle | undefined
  let frameTimer: TimerHandle | undefined
  let framePending = false
  let flushing = false

  const cancelFrameRequests = () => {
    if (frameHandle !== undefined && frames) frames.cancel(frameHandle)
    if (frameTimer !== undefined) clock.clearTimeout(frameTimer)
    frameHandle = undefined
    frameTimer = undefined
    framePending = false
  }

  const flushFrame = () => {
    cancelFrameRequests()
    if (frameQueue.length === 0 || flushing) return
    // Work queued while flushing runs in this same batch.
    flushing = true
    try {
      batch(() => {
        for (let i = 0; i < frameQueue.length; i++) {
          const fn = frameQueue[i]!
          try {
            fn()
          } catch (error) {
            onError(error)
          }
        }
        frameQueue = []
      })
    } finally {
      flushing = false
    }
    // Effects run when the batch ends, after the queue was emptied. Anything
    // they queued (a patch that arrives in the same turn from an in-process
    // core, for example) belongs to the next frame and must not be stranded.
    if (frameQueue.length > 0) requestFrame()
  }

  function requestFrame() {
    if (framePending) return
    framePending = true
    if (frames && !isHidden?.()) {
      frameHandle = frames.request(flushFrame)
      frameTimer = clock.setTimeout(flushFrame, frameSafetyMs)
    } else {
      frameTimer = clock.setTimeout(flushFrame, frameFallbackMs)
    }
  }

  // Idle lane -----------------------------------------------------------------

  const idleQueue: IdleTask[] = []
  let idleHandle: TimerHandle | undefined
  let idleTimer: TimerHandle | undefined

  const runIdle = (deadline: IdleDeadline) => {
    idleHandle = undefined
    idleTimer = undefined
    // One pass over the tasks queued at the start of this slice; a task that
    // yields goes to the back of the queue.
    // The first task always runs: an idle callback that fires on its timeout
    // (a busy page) reports no time remaining, and running nothing then would
    // strand the queue for as long as the page stays busy.
    let budget = idleQueue.length
    let ran = false
    while (budget > 0 && idleQueue.length > 0 && (!ran || deadline.timeRemaining() > 0)) {
      ran = true
      budget -= 1
      const task = idleQueue.shift()!
      let more: boolean | void = false
      try {
        more = task(deadline)
      } catch (error) {
        onError(error)
      }
      if (more === true) idleQueue.push(task)
    }
    if (idleQueue.length > 0) requestIdle()
  }

  const requestIdle = () => {
    if (idleHandle !== undefined || idleTimer !== undefined) return
    if (idleSource) {
      idleHandle = idleSource.request(runIdle)
      return
    }
    idleTimer = clock.setTimeout(() => {
      const start = clock.now()
      runIdle({ timeRemaining: () => Math.max(0, idleSliceMs - (clock.now() - start)) })
    }, idleGapMs)
  }

  const cancelIdle = () => {
    if (idleHandle !== undefined && idleSource) idleSource.cancel(idleHandle)
    if (idleTimer !== undefined) clock.clearTimeout(idleTimer)
    idleHandle = undefined
    idleTimer = undefined
  }

  return {
    sync: (fn) => batch(fn),
    frame: (fn) => {
      frameQueue.push(fn)
      if (!flushing) requestFrame()
    },
    flushFrame,
    idle: (task) => {
      idleQueue.push(task)
      requestIdle()
      return () => {
        const index = idleQueue.indexOf(task)
        if (index >= 0) idleQueue.splice(index, 1)
        if (idleQueue.length === 0) cancelIdle()
      }
    },
    dispose: () => {
      cancelFrameRequests()
      cancelIdle()
      frameQueue = []
      idleQueue.length = 0
    },
  }
}

// ---------------------------------------------------------------------------
// Browser wiring

type BrowserGlobals = {
  requestAnimationFrame?: (fn: (time: number) => void) => number
  cancelAnimationFrame?: (handle: number) => void
  requestIdleCallback?: (fn: (deadline: IdleDeadline) => void, options?: { timeout: number }) => number
  cancelIdleCallback?: (handle: number) => void
  document?: { visibilityState?: string }
  performance?: { now(): number }
}

export const browserClock = (): Clock => {
  const g = globalThis as BrowserGlobals
  return {
    now: () => (g.performance ? g.performance.now() : Date.now()),
    setTimeout: (fn, ms) => globalThis.setTimeout(fn, ms),
    clearTimeout: (handle) => globalThis.clearTimeout(handle as ReturnType<typeof globalThis.setTimeout>),
  }
}

/**
 * The scheduler for a browser window. Uses `requestAnimationFrame` while the
 * page is visible and a timer otherwise; uses `requestIdleCallback` where it
 * exists (not in Safari) and timer slices otherwise.
 */
export const browserScheduler = (overrides?: Partial<SchedulerOptions>): Scheduler => {
  const g = globalThis as BrowserGlobals
  const raf = g.requestAnimationFrame
  const caf = g.cancelAnimationFrame
  const ric = g.requestIdleCallback
  const cic = g.cancelIdleCallback
  return createScheduler({
    clock: browserClock(),
    ...(raf && caf
      ? {
          frames: {
            request: (fn) => raf.call(globalThis, () => fn()),
            cancel: (handle) => caf.call(globalThis, handle as number),
          },
        }
      : {}),
    ...(ric && cic
      ? {
          idleSource: {
            request: (fn) => ric.call(globalThis, fn, { timeout: 1000 }),
            cancel: (handle) => cic.call(globalThis, handle as number),
          },
        }
      : {}),
    isHidden: () => g.document?.visibilityState === "hidden",
    ...overrides,
  })
}

// ---------------------------------------------------------------------------
// A manual clock and frame source for tests and labs

export interface ManualTime extends Clock {
  readonly frames: FrameSource
  readonly idleSource: IdleSource
  /** Advance the clock, running timers that come due, in order. */
  advance(ms: number): void
  /** Run the pending frame callbacks, as a browser does before paint. */
  frame(): void
  /** Run pending idle callbacks with `budgetMs` of idle time each. */
  idle(budgetMs?: number): void
  pendingFrames(): number
  pendingTimers(): number
}

/** Deterministic time for tests: nothing runs until the test says so. */
export const manualTime = (): ManualTime => {
  let now = 0
  let nextId = 1
  const timers = new Map<number, { at: number; fn: () => void }>()
  const frameCallbacks = new Map<number, () => void>()
  const idleCallbacks = new Map<number, (deadline: IdleDeadline) => void>()

  const time: ManualTime = {
    now: () => now,
    setTimeout: (fn, ms) => {
      const id = nextId++
      timers.set(id, { at: now + Math.max(0, ms), fn })
      return id
    },
    clearTimeout: (handle) => {
      timers.delete(handle as number)
    },
    frames: {
      request: (fn) => {
        const id = nextId++
        frameCallbacks.set(id, fn)
        return id
      },
      cancel: (handle) => {
        frameCallbacks.delete(handle as number)
      },
    },
    idleSource: {
      request: (fn) => {
        const id = nextId++
        idleCallbacks.set(id, fn)
        return id
      },
      cancel: (handle) => {
        idleCallbacks.delete(handle as number)
      },
    },
    advance: (ms) => {
      const target = now + ms
      for (;;) {
        let dueId: number | undefined
        let due: { at: number; fn: () => void } | undefined
        for (const [id, timer] of timers) {
          if (timer.at <= target && (due === undefined || timer.at < due.at)) {
            dueId = id
            due = timer
          }
        }
        if (dueId === undefined || due === undefined) break
        timers.delete(dueId)
        now = due.at
        due.fn()
      }
      // A timer may have advanced the clock itself; never go back.
      now = Math.max(now, target)
    },
    frame: () => {
      const callbacks = [...frameCallbacks.values()]
      frameCallbacks.clear()
      for (const fn of callbacks) fn()
    },
    idle: (budgetMs = 10) => {
      const callbacks = [...idleCallbacks.values()]
      idleCallbacks.clear()
      for (const fn of callbacks) {
        const start = now
        fn({ timeRemaining: () => Math.max(0, budgetMs - (now - start)) })
      }
    },
    pendingFrames: () => frameCallbacks.size,
    pendingTimers: () => timers.size,
  }
  return time
}
