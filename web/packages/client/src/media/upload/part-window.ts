import {
  UPLOAD_WINDOW_INITIAL,
  UPLOAD_WINDOW_MAX,
  UPLOAD_WINDOW_MIN,
  WINDOW_GROW_BELOW_MS,
  WINDOW_SHRINK_ABOVE_MS,
} from "../constants"
import { canceled } from "../types"

type Waiter = { resolve: () => void; reject: (error: Error) => void; cleanup: () => void }

/**
 * Part slots shared by every upload, as in `DurableUploadCoordinator`: a part
 * accepted in under 1 s grows the window by one, one over 2 s halves it, and a
 * part that needed another attempt halves it. Waiters are served in arrival
 * order, so uploads take turns.
 */
export class PartWindow {
  #size: number
  #active = 0
  readonly #waiters: Waiter[] = []
  /** Every size the window took, for tests and diagnostics. */
  readonly history: number[] = []

  constructor(
    readonly min = UPLOAD_WINDOW_MIN,
    readonly max = UPLOAD_WINDOW_MAX,
    initial = UPLOAD_WINDOW_INITIAL,
  ) {
    if (!(min >= 1 && max >= min && initial >= min && initial <= max)) throw new RangeError("Invalid window limits")
    this.#size = initial
    this.history.push(initial)
  }

  get size(): number {
    return this.#size
  }

  get active(): number {
    return this.#active
  }

  get waiting(): number {
    return this.#waiters.length
  }

  /** A slot now, or nothing; never waits. */
  tryAcquire(): boolean {
    if (this.#active >= this.#size || this.#waiters.length > 0) return false
    this.#active += 1
    return true
  }

  acquire(signal?: AbortSignal): Promise<void> {
    if (signal?.aborted) return Promise.reject(canceled())
    if (this.tryAcquire()) return Promise.resolve()
    return new Promise<void>((resolve, reject) => {
      const onAbort = () => {
        const index = this.#waiters.indexOf(waiter)
        if (index >= 0) this.#waiters.splice(index, 1)
        reject(canceled())
      }
      const waiter: Waiter = {
        resolve,
        reject,
        cleanup: () => signal?.removeEventListener("abort", onAbort),
      }
      signal?.addEventListener("abort", onAbort, { once: true })
      this.#waiters.push(waiter)
    })
  }

  /** Returns a slot. `latencyMs` adapts the window after a part was accepted; `failed` halves it. */
  release(outcome: { latencyMs?: number; failed?: boolean } = {}): void {
    this.#active -= 1
    if (outcome.failed) {
      this.#resize(Math.max(Math.floor(this.#size / 2), this.min))
    } else if (outcome.latencyMs !== undefined) {
      this.#resize(adaptedWindow(this.#size, outcome.latencyMs, this.min, this.max))
    }
    while (this.#active < this.#size && this.#waiters.length > 0) {
      this.#active += 1
      const waiter = this.#waiters.shift()!
      waiter.cleanup()
      waiter.resolve()
    }
  }

  #resize(size: number): void {
    if (size === this.#size) return
    this.#size = size
    this.history.push(size)
  }
}

export const adaptedWindow = (window: number, latencyMs: number, min = UPLOAD_WINDOW_MIN, max = UPLOAD_WINDOW_MAX): number => {
  if (latencyMs < WINDOW_GROW_BELOW_MS) return Math.min(window + 1, max)
  if (latencyMs > WINDOW_SHRINK_ABOVE_MS) return Math.max(Math.floor(window / 2), min)
  return window
}
