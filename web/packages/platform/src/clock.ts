/**
 * Time, injected. The same shape as `Clock` in `@inline/reactive` (its
 * scheduler) and in `@inline/link`, so one object serves all three without
 * the packages importing each other.
 */

export type TimerHandle = unknown

export interface Clock {
  /** Milliseconds. Wall-clock time for the wake detector; see `systemClock`. */
  now(): number
  setTimeout(fn: () => void, ms: number): TimerHandle
  clearTimeout(handle: TimerHandle): void
}

/**
 * `Date.now` and the global timers, read when called, not when imported.
 * Wall-clock on purpose: the wake detector needs time that keeps running while
 * the machine sleeps, which `performance.now` does not guarantee.
 */
export const systemClock = (): Clock => ({
  now: () => Date.now(),
  setTimeout: (fn, ms) => globalThis.setTimeout(fn, ms),
  clearTimeout: (handle) => globalThis.clearTimeout(handle as ReturnType<typeof globalThis.setTimeout>),
})
