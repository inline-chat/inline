/**
 * Time for controllers. Every delay (tooltips, typeahead, hover intent,
 * toasts) goes through a Clock so tests drive time with a manual clock and
 * never sleep.
 */

export type TimerHandle = { readonly __timer: unique symbol }

export interface Clock {
  now(): number
  setTimeout(fn: () => void, ms: number): TimerHandle
  clearTimeout(handle: TimerHandle | null | undefined): void
}

export const systemClock: Clock = {
  now: () => performance.now(),
  setTimeout: (fn, ms) => globalThis.setTimeout(fn, ms) as unknown as TimerHandle,
  clearTimeout: (handle) => {
    if (handle != null) globalThis.clearTimeout(handle as unknown as ReturnType<typeof setTimeout>)
  },
}

export interface ManualClock extends Clock {
  /** Move time forward, running due timers in order. */
  advance(ms: number): void
  /** Timers still waiting. */
  pending(): number
}

/** A clock that only moves when a test says so. */
export const createManualClock = (start = 0): ManualClock => {
  let time = start
  let nextId = 1
  const timers = new Map<number, { at: number; fn: () => void }>()
  return {
    now: () => time,
    setTimeout(fn, ms) {
      const id = nextId++
      timers.set(id, { at: time + Math.max(0, ms), fn })
      return id as unknown as TimerHandle
    },
    clearTimeout(handle) {
      if (handle != null) timers.delete(handle as unknown as number)
    },
    advance(ms) {
      const end = time + ms
      for (;;) {
        let dueId: number | undefined
        let dueAt = Infinity
        for (const [id, timer] of timers) {
          if (timer.at <= end && timer.at < dueAt) {
            dueAt = timer.at
            dueId = id
          }
        }
        if (dueId === undefined) break
        const timer = timers.get(dueId)
        timers.delete(dueId)
        time = dueAt
        timer?.fn()
      }
      time = end
    },
    pending: () => timers.size,
  }
}

/** A single restartable timer, the shape most controllers need. */
export class Timer {
  #handle: TimerHandle | null = null
  constructor(private readonly clock: Clock) {}

  start(ms: number, fn: () => void): void {
    this.stop()
    this.#handle = this.clock.setTimeout(() => {
      this.#handle = null
      fn()
    }, ms)
  }

  stop(): void {
    this.clock.clearTimeout(this.#handle)
    this.#handle = null
  }

  get running(): boolean {
    return this.#handle !== null
  }
}
