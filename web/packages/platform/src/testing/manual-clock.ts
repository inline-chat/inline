import type { Clock, TimerHandle } from "../clock"

export interface ManualClock extends Clock {
  /** Move time forward, running each timer that comes due at its own time. */
  advance(ms: number): void
  /**
   * The machine sleeps for `ms`: time jumps forward with no timer running in
   * between, then timers that are due run, all at the new time.
   */
  sleep(ms: number): void
  pendingTimers(): number
}

/** Deterministic wall-clock time. Starts at `start` (ms since the epoch). */
export const manualClock = (start = 1_700_000_000_000): ManualClock => {
  let now = start
  let nextId = 1
  const timers = new Map<number, { at: number; fn: () => void }>()

  const runDue = (until: number, jumpToTimer: boolean) => {
    for (;;) {
      let dueId: number | undefined
      let due: { at: number; fn: () => void } | undefined
      for (const [id, timer] of timers) {
        if (timer.at <= until && (due === undefined || timer.at < due.at)) {
          dueId = id
          due = timer
        }
      }
      if (dueId === undefined || due === undefined) break
      timers.delete(dueId)
      if (jumpToTimer) now = Math.max(now, due.at)
      due.fn()
    }
  }

  return {
    now: () => now,
    setTimeout(fn, ms): TimerHandle {
      const id = nextId++
      timers.set(id, { at: now + Math.max(0, ms), fn })
      return id
    },
    clearTimeout(handle) {
      timers.delete(handle as number)
    },
    advance(ms) {
      const target = now + ms
      runDue(target, true)
      now = target
    },
    sleep(ms) {
      now += ms
      runDue(now, false)
    },
    pendingTimers: () => timers.size,
  }
}
