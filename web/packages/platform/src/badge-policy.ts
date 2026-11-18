/**
 * When the badge count changes on screen. Ported from the Mac
 * `DockBadgeController` (`apple/InlineMac/Services/DockBadge/`): decreases
 * apply at once; increases wait 500 ms, so a message that arrives and is read
 * straight away never flickers the badge. A newer `set` supersedes a pending
 * increase.
 */

import type { Clock, TimerHandle } from "./clock"

export const BADGE_INCREASE_DEBOUNCE_MS = 500

export interface BadgeController {
  /** `immediate` skips the debounce (sign-in, sign-out, badge re-enabled). */
  set(count: number, immediate?: boolean): void
  /** The count last applied. */
  readonly applied: number
  /** Drop a pending increase. */
  dispose(): void
}

export const createBadgeController = (options: {
  readonly clock: Clock
  /** Show the count. Called only when the shown value should change. */
  readonly apply: (count: number) => void
  readonly debounceMs?: number
  /** The count already on display. Defaults to 0. */
  readonly initial?: number
}): BadgeController => {
  const { clock, apply } = options
  const debounceMs = options.debounceMs ?? BADGE_INCREASE_DEBOUNCE_MS
  let applied = normalizeCount(options.initial ?? 0)
  let pending: TimerHandle | undefined

  const cancel = () => {
    if (pending === undefined) return
    clock.clearTimeout(pending)
    pending = undefined
  }

  const applyNow = (count: number) => {
    if (count === applied) return
    applied = count
    apply(count)
  }

  return {
    set(raw, immediate = false) {
      const count = normalizeCount(raw)
      cancel()
      if (immediate || count <= applied) {
        applyNow(count)
        return
      }
      pending = clock.setTimeout(() => {
        pending = undefined
        applyNow(count)
      }, debounceMs)
    },
    get applied() {
      return applied
    },
    dispose: cancel,
  }
}

/** Non-negative integers only; anything else is 0. */
export const normalizeCount = (count: number): number =>
  Number.isFinite(count) && count > 0 ? Math.floor(count) : 0

/** The text on a badge: none for 0, "99+" above 99, as on the dock. */
export const badgeLabel = (count: number): string | null => {
  const n = normalizeCount(count)
  if (n === 0) return null
  return n > 99 ? "99+" : String(n)
}
