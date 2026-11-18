/**
 * Keeps the platform badge equal to the session's count of prominent unread
 * chats (feature-map rule 9, the Mac `DockBadgeService`). The platform's
 * badge applies the Mac debounce: decreases at once, increases after 500 ms.
 *
 * The first value after sign-in is applied at once, as is the value after the
 * badge setting is turned back on; sign-out and dispose clear it at once.
 */

import { effect, untracked, type Dispose, type ReadSignal } from "@inline/reactive"

export type BadgeTarget = { set(count: number, options?: { immediate?: boolean }): void }

export type BadgeControllerOptions = {
  /** `AccountSession.badgeCount`. */
  readonly count: ReadSignal<number>
  /** `platform.badge`. */
  readonly badge: BadgeTarget
  /** The user's badge setting (Mac Settings, Notifications). Default on. */
  readonly enabled?: ReadSignal<boolean>
}

export const attachBadge = (options: BadgeControllerOptions): Dispose => {
  const { badge } = options
  let wasShown = false
  const stop = effect(() => {
    const enabled = options.enabled?.get() ?? true
    const count = enabled ? options.count.get() : 0
    untracked(() => badge.set(count, wasShown && enabled ? {} : { immediate: true }))
    wasShown = enabled
  })
  let disposed = false
  return () => {
    if (disposed) return
    disposed = true
    stop()
    badge.set(0, { immediate: true })
  }
}
