/**
 * Sends a chat's read frontier with the Mac client's coalescing and retry
 * rules (`InlineKit/ViewModels/UnreadManager.swift`:
 * `AutomaticReadCoalescingState`, `AutomaticReadRetryPolicy`):
 *
 * - One `markRead` is in flight at a time. A higher frontier asked for
 *   meanwhile waits; a still higher one replaces it.
 * - Never sends a frontier at or below one that succeeded, nor below the
 *   last one attempted: a later visibility pass cannot regress a marker that
 *   may already have committed.
 * - A retryable failure retries the in-flight frontier (or the waiting one,
 *   if higher) after 0.5 s, doubling to at most 8 s, with jitter of ±20%.
 *   Success resets the backoff.
 */

import type { IntentRejection, IntentResult } from "@inline/core-protocol"
import type { MessageID } from "@inline/ids"
import type { Clock } from "@inline/reactive"
import { compareMessageIds } from "./helpers"

export const readRetryBaseMs = 500
export const readRetryMaxMs = 8_000

/** Mac `AutomaticReadRetryPolicy.delaySeconds`, in milliseconds. `jitterUnit` is in [0, 1]. */
export const readRetryDelayMs = (failureCount: number, jitterUnit: number): number => {
  const exponent = Math.min(Math.max(0, failureCount - 1), 4)
  const exponential = readRetryBaseMs * 2 ** exponent
  const unit = Math.min(1, Math.max(0, jitterUnit))
  return Math.round(Math.min(readRetryMaxMs, exponential * (0.8 + 0.4 * unit)))
}

/** Rejections that will not change by trying again. */
const permanentRejections: ReadonlySet<IntentRejection | undefined> = new Set<IntentRejection | undefined>([
  "invalid",
  "unsupported",
  "notSignedIn",
])

export type ReadMarkerOptions = {
  /** Posts the `markRead` intent and resolves with its first result. */
  readonly send: (maxId: MessageID) => Promise<IntentResult>
  readonly clock: Clock
  /** Returns a number in [0, 1) for the jitter. Tests pass a constant. */
  readonly random?: () => number
}

export class ReadMarker {
  readonly #options: ReadMarkerOptions
  #inFlight: MessageID | undefined
  #pending: MessageID | undefined
  #highestSucceeded: MessageID | undefined
  #lastAttempted: MessageID | undefined
  #failures = 0
  #retryTimer: unknown
  #disposed = false

  constructor(options: ReadMarkerOptions) {
    this.#options = options
  }

  /** The highest frontier the core accepted. */
  get succeeded(): MessageID | undefined {
    return this.#highestSucceeded
  }

  get inFlight(): MessageID | undefined {
    return this.#inFlight
  }

  /** Ask for the frontier to reach `maxId`. Lower or repeated requests are ignored. */
  mark(maxId: MessageID): void {
    if (this.#disposed) return
    if (this.#inFlight === undefined) {
      if (this.#highestSucceeded !== undefined && compareMessageIds(maxId, this.#highestSucceeded) <= 0) return
      if (this.#lastAttempted !== undefined && compareMessageIds(maxId, this.#lastAttempted) < 0) return
      this.#start(maxId)
      return
    }
    const watermark = this.#pending !== undefined && compareMessageIds(this.#pending, this.#inFlight) > 0 ? this.#pending : this.#inFlight
    if (compareMessageIds(maxId, watermark) <= 0) return
    this.#pending = maxId
  }

  dispose(): void {
    this.#disposed = true
    if (this.#retryTimer !== undefined) this.#options.clock.clearTimeout(this.#retryTimer)
    this.#retryTimer = undefined
  }

  #start(maxId: MessageID) {
    this.#lastAttempted = maxId
    this.#inFlight = maxId
    this.#options.send(maxId).then(
      (result) => this.#settle(maxId, result.status, result.reason),
      () => this.#settle(maxId, "rejected", "unavailable"),
    )
  }

  #settle(sent: MessageID, status: IntentResult["status"], reason: IntentRejection | undefined) {
    if (this.#disposed || this.#inFlight !== sent) return
    if (status === "accepted" || status === "confirmed") {
      this.#failures = 0
      this.#inFlight = undefined
      if (this.#highestSucceeded === undefined || compareMessageIds(sent, this.#highestSucceeded) > 0) {
        this.#highestSucceeded = sent
      }
      this.#startPending()
      return
    }
    if (status === "rejected" && permanentRejections.has(reason)) {
      // Nothing to gain from retrying this one; a higher frontier still goes.
      this.#failures = 0
      this.#inFlight = undefined
      this.#startPending()
      return
    }
    // Retryable: storage full, unavailable, a server error, or uncertain.
    this.#failures += 1
    const delay = readRetryDelayMs(this.#failures, this.#options.random?.() ?? Math.random())
    this.#retryTimer = this.#options.clock.setTimeout(() => {
      this.#retryTimer = undefined
      if (this.#disposed) return
      const target = this.#pending !== undefined && compareMessageIds(this.#pending, sent) > 0 ? this.#pending : sent
      this.#pending = undefined
      this.#start(target)
    }, delay)
  }

  #startPending() {
    const next = this.#pending
    this.#pending = undefined
    if (next === undefined) return
    if (this.#highestSucceeded !== undefined && compareMessageIds(next, this.#highestSucceeded) <= 0) return
    this.#start(next)
  }
}
