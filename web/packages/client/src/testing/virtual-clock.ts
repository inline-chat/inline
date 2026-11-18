import { vi } from "vitest"
import { realTurn } from "./event-loop"

/**
 * Deterministic time for tests.
 *
 * Two implementations share one driving API (`TestClock`):
 *
 * - `VirtualClock` is a pure timer queue for code that takes a clock as a
 *   dependency (`now`, `setTimeout`, `clearTimeout`). It touches no globals.
 * - `useFakeTime()` installs Vitest fake timers for code that still calls the
 *   global `setTimeout` and `Date.now` (most of the core today), and drives
 *   them through the same API.
 *
 * Both advance time only when the test says so, and both run due timers in
 * deadline order with every pending promise flushed between them. `settle`
 * also yields real event-loop turns, because SQLite WASM initialization does
 * real I/O that fake timers do not control.
 */

/** 2026-01-01T00:00:00Z. A fixed, recognizable start for every test. */
export const DEFAULT_START_MS = 1_767_225_600_000

export type SettleOptions = {
  /**
   * A value that changes whenever the system makes progress (a frame count,
   * a database revision). Settling stops once it has been stable for
   * `quietRounds` rounds. Without it, settling runs `quietRounds` rounds.
   */
  progress?: () => unknown
  quietRounds?: number
  maxRounds?: number
}

export type RunUntilOptions = SettleOptions & {
  /** Virtual time to advance between checks. Default 100 ms. */
  stepMs?: number
  /** Give up after this much virtual time. Default 60 s. */
  maxMs?: number
  /** Shown in the error when the condition never holds. */
  description?: string
}

export interface TestClock {
  /** Current virtual time in milliseconds since the epoch. */
  now(): number
  /** Current virtual time in whole seconds, as the protocol counts dates. */
  nowSeconds(): number
  /** Move time forward, running every timer that falls due, in order. */
  advance(ms: number): Promise<void>
  /** Run pending promises and zero-delay timers until nothing moves. */
  settle(options?: SettleOptions): Promise<void>
  /** Settle, check, advance by a step, repeat, until the predicate holds. */
  runUntil(predicate: () => boolean, options?: RunUntilOptions): Promise<void>
  /** Timers still scheduled. */
  pendingTimers(): number
}

export { realTurn }

const settleLoop = async (
  step: () => Promise<void>,
  options: SettleOptions = {},
) => {
  const quietRounds = options.quietRounds ?? 3
  const maxRounds = options.maxRounds ?? 2_000
  let previous = options.progress?.()
  let quiet = 0
  for (let round = 0; round < maxRounds; round += 1) {
    await step()
    const current = options.progress?.()
    if (Object.is(current, previous)) {
      quiet += 1
      if (quiet >= quietRounds) return
    } else {
      quiet = 0
      previous = current
    }
  }
  throw new Error(
    `System did not settle within ${maxRounds} rounds; something is busy-looping`,
  )
}

const runUntilLoop = async (
  clock: TestClock,
  predicate: () => boolean,
  options: RunUntilOptions = {},
) => {
  const stepMs = options.stepMs ?? 100
  const maxMs = options.maxMs ?? 60_000
  const start = clock.now()
  while (true) {
    await clock.settle(options)
    if (predicate()) return
    if (clock.now() - start >= maxMs) {
      throw new Error(
        `Condition never held within ${maxMs} ms of virtual time` +
          (options.description ? `: ${options.description}` : ""),
      )
    }
    await clock.advance(stepMs)
  }
}

type ScheduledTimer = {
  id: number
  deadline: number
  order: number
  callback: () => void
}

/**
 * A pure, injectable clock. Pass `clock.now`, `clock.setTimeout` and
 * `clock.clearTimeout` to the code under test.
 */
export class VirtualClock implements TestClock {
  private currentMs: number
  private nextId = 1
  private nextOrder = 0
  private readonly timers = new Map<number, ScheduledTimer>()

  constructor(startMs = DEFAULT_START_MS) {
    this.currentMs = startMs
  }

  now = () => this.currentMs

  nowSeconds = () => Math.floor(this.currentMs / 1_000)

  setTimeout = (callback: () => void, delayMs = 0): number => {
    const id = this.nextId++
    this.timers.set(id, {
      id,
      deadline: this.currentMs + Math.max(0, delayMs),
      order: this.nextOrder++,
      callback,
    })
    return id
  }

  clearTimeout = (id: number | undefined | null) => {
    if (id != null) this.timers.delete(id)
  }

  pendingTimers() {
    return this.timers.size
  }

  /** The deadline of the next timer, if any. */
  nextDeadline(): number | undefined {
    return this.nextTimer()?.deadline
  }

  async advance(ms: number) {
    if (ms < 0) throw new RangeError("Time does not go backwards")
    const target = this.currentMs + ms
    await realTurn()
    while (true) {
      const timer = this.nextTimer()
      if (!timer || timer.deadline > target) break
      this.timers.delete(timer.id)
      this.currentMs = Math.max(this.currentMs, timer.deadline)
      timer.callback()
      await realTurn()
    }
    this.currentMs = target
  }

  /** Run timers until none are left, up to a safety cap. */
  async runAll(maxTimers = 10_000) {
    for (let count = 0; count < maxTimers; count += 1) {
      const deadline = this.nextDeadline()
      if (deadline == null) return
      await this.advance(deadline - this.currentMs)
    }
    throw new Error(`More than ${maxTimers} timers ran; a timer reschedules itself forever`)
  }

  async settle(options?: SettleOptions) {
    await settleLoop(async () => {
      await realTurn()
      await this.advance(0)
    }, options)
  }

  runUntil(predicate: () => boolean, options?: RunUntilOptions) {
    return runUntilLoop(this, predicate, options)
  }

  private nextTimer(): ScheduledTimer | undefined {
    let next: ScheduledTimer | undefined
    for (const timer of this.timers.values()) {
      if (
        !next ||
        timer.deadline < next.deadline ||
        (timer.deadline === next.deadline && timer.order < next.order)
      ) {
        next = timer
      }
    }
    return next
  }
}

export type FakeTime = TestClock & {
  /** Restore real timers. Call in `afterEach` or a `finally`. */
  dispose(): void
}

/**
 * Replace the global `setTimeout`, `setInterval` and `Date` with Vitest fake
 * timers and return a `TestClock` that drives them. `setImmediate`,
 * `queueMicrotask` and `process.nextTick` stay real, so promise chains and
 * SQLite WASM start-up still run.
 */
export const useFakeTime = (
  options: { startMs?: number } = {},
): FakeTime => {
  vi.useFakeTimers({
    now: options.startMs ?? DEFAULT_START_MS,
    toFake: [
      "setTimeout",
      "clearTimeout",
      "setInterval",
      "clearInterval",
      "Date",
    ],
  })
  let disposed = false
  const clock: FakeTime = {
    now: () => Date.now(),
    nowSeconds: () => Math.floor(Date.now() / 1_000),
    async advance(ms: number) {
      if (ms < 0) throw new RangeError("Time does not go backwards")
      await realTurn()
      await vi.advanceTimersByTimeAsync(ms)
      await realTurn()
    },
    async settle(settleOptions?: SettleOptions) {
      await settleLoop(async () => {
        await realTurn()
        await vi.advanceTimersByTimeAsync(0)
      }, settleOptions)
    },
    runUntil(predicate, runOptions) {
      return runUntilLoop(clock, predicate, runOptions)
    },
    pendingTimers: () => vi.getTimerCount(),
    dispose() {
      if (disposed) return
      disposed = true
      vi.useRealTimers()
    },
  }
  return clock
}
