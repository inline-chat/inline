/** Idle pollers never wait longer than this between database reads. */
export const MAXIMUM_IDLE_POLL_INTERVAL_MS = 15_000

/** Sixteen base intervals, capped so a 1 s poller still reaches the cap. */
export const defaultMaximumIdleIntervalMs = (pollIntervalMs: number): number =>
  Math.min(MAXIMUM_IDLE_POLL_INTERVAL_MS, 16 * pollIntervalMs)

/**
 * Doubles the gap between polls while they come back empty and resets it to
 * one base interval as soon as a poll finds work or the owner is told that
 * work exists. Fixed-interval workers keep their timer and ask `due()` on
 * each tick; timeout-chained workers multiply their base delay by
 * `multiplier`. Either way a busy worker still polls every base interval.
 */
export class IdleBackoff {
  #multiplier = 1
  #skippedTicks = 0

  constructor(private readonly maximumMultiplier: number) {
    if (!Number.isSafeInteger(maximumMultiplier) || maximumMultiplier < 1) {
      throw new RangeError("Idle backoff needs a positive integer maximum multiplier")
    }
  }

  static forInterval(pollIntervalMs: number, maximumIdleIntervalMs = defaultMaximumIdleIntervalMs(pollIntervalMs)): IdleBackoff {
    return new IdleBackoff(Math.max(1, Math.floor(maximumIdleIntervalMs / pollIntervalMs)))
  }

  /** Base intervals between polls right now. */
  get multiplier(): number {
    return this.#multiplier
  }

  /** Whether a fixed-interval tick should poll; skipped ticks count toward the gap. */
  due(): boolean {
    if (this.#skippedTicks + 1 < this.#multiplier) {
      this.#skippedTicks += 1
      return false
    }
    this.#skippedTicks = 0
    return true
  }

  /** Record a completed poll: work resets the gap, an empty poll doubles it. */
  observe(foundWork: boolean): void {
    this.#multiplier = foundWork ? 1 : Math.min(this.maximumMultiplier, this.#multiplier * 2)
    this.#skippedTicks = 0
  }

  /** An in-process or broker hint that work exists: poll at the next base interval. */
  reset(): void {
    this.#multiplier = 1
    this.#skippedTicks = 0
  }
}
