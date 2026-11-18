/**
 * Detects that the machine slept: a repeating timer that fires much later
 * than scheduled. Browsers have no sleep event; this is the usual signal.
 *
 * The tolerance must exceed timer throttling, or a throttled background tab
 * looks like a wake: Chrome aligns timers of pages hidden for five minutes to
 * one-minute boundaries. The default (interval 10 s, tolerance 65 s) reports
 * sleeps longer than about 75 s. A frozen page that resumes after a long time
 * also reports a wake, which is what the connection wants anyway.
 */

import type { Clock, TimerHandle } from "./clock"

export const WAKE_INTERVAL_MS = 10_000
export const WAKE_TOLERANCE_MS = 65_000

export interface WakeDetector {
  /** Check now (call on visibility or focus regain to notice a wake sooner). */
  check(): void
  dispose(): void
}

export const createWakeDetector = (options: {
  /** Wall-clock time: it must keep running while the machine sleeps. */
  readonly clock: Clock
  readonly onWake: (gapMs: number) => void
  readonly intervalMs?: number
  readonly toleranceMs?: number
}): WakeDetector => {
  const { clock, onWake } = options
  const intervalMs = options.intervalMs ?? WAKE_INTERVAL_MS
  const toleranceMs = options.toleranceMs ?? WAKE_TOLERANCE_MS
  let last = clock.now()
  let timer: TimerHandle | undefined
  let disposed = false

  const check = () => {
    if (disposed) return
    const now = clock.now()
    const gap = now - last
    last = now
    if (gap > intervalMs + toleranceMs) onWake(gap)
  }

  const schedule = () => {
    timer = clock.setTimeout(() => {
      timer = undefined
      check()
      if (!disposed) schedule()
    }, intervalMs)
  }

  schedule()

  return {
    check,
    dispose() {
      disposed = true
      if (timer !== undefined) clock.clearTimeout(timer)
      timer = undefined
    },
  }
}
