/**
 * Small time-driven state for content views: the live "Working" timer of a
 * running disclosure, and the brief "Copied" confirmation of a copy button.
 * Time goes through the UI kit's `Clock`, so tests use a manual clock.
 */

import { formatElapsed } from "@inline/chat-ui"
import { type ReadSignal, signal } from "@inline/reactive"
import { type Clock, systemClock, Timer } from "@inline/ui"

export type ElapsedTimerOptions = {
  readonly clock?: Clock
  /** Wall time in seconds since the epoch. Default `Date.now() / 1000`. */
  readonly nowSeconds?: () => number
}

/** "8s", "1m 4s" from `startedAt` (seconds since the epoch), ticking once a second. */
export class ElapsedTimer {
  readonly #text: ReturnType<typeof signal<string | undefined>>
  readonly #timer: Timer
  readonly #now: () => number
  readonly #startedAt: number
  #disposed = false

  constructor(startedAt: number, options: ElapsedTimerOptions = {}) {
    this.#startedAt = startedAt
    this.#now = options.nowSeconds ?? (() => Date.now() / 1000)
    this.#timer = new Timer(options.clock ?? systemClock)
    this.#text = signal(formatElapsed(startedAt, this.#now()))
    this.#schedule()
  }

  get text(): ReadSignal<string | undefined> {
    return this.#text
  }

  dispose(): void {
    this.#disposed = true
    this.#timer.stop()
  }

  #schedule(): void {
    if (this.#disposed) return
    const now = this.#now()
    // Tick on the next whole second of elapsed time.
    const fraction = (now - this.#startedAt) % 1
    const delay = Math.max(50, Math.round((1 - (fraction < 0 ? fraction + 1 : fraction)) * 1000))
    this.#timer.start(delay, () => {
      this.#text.set(formatElapsed(this.#startedAt, this.#now()))
      this.#schedule()
    })
  }
}

/** A flag that turns itself off: `trigger()` sets it for `duration` ms. */
export class TransientFlag {
  readonly #on = signal(false)
  readonly #timer: Timer
  readonly #duration: number

  constructor(duration = 1500, clock: Clock = systemClock) {
    this.#duration = duration
    this.#timer = new Timer(clock)
  }

  get on(): ReadSignal<boolean> {
    return this.#on
  }

  trigger(): void {
    this.#on.set(true)
    this.#timer.start(this.#duration, () => this.#on.set(false))
  }

  dispose(): void {
    this.#timer.stop()
  }
}
