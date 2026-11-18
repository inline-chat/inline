/**
 * The one call the app shell makes per signed-in session: wires the badge,
 * the message notifications and the permission affordance, and returns the
 * function that undoes it on sign-out.
 *
 * ```ts
 * const notifications = attachNotifications({
 *   session,                       // AccountSession
 *   platform,                      // Platform from @inline/platform
 *   role: runtime.role,            // the link role of this context
 *   clock: systemClock(),          // wall clock (@inline/platform)
 *   storage: localStorage,
 *   channel: new BroadcastChannel(`inline-notify/${apiOrigin}/${session.userId}`),
 * })
 * notifications.prompt.showPrompt  // for the "Turn on notifications" banner
 * notifications()                  // on sign-out (also closes the channel)
 * ```
 */

import type { Platform } from "@inline/platform"
import type { Dispose, ReadSignal } from "@inline/reactive"
import { attachBadge } from "./badge"
import {
  createNotificationController,
  type CoreRole,
  type NotificationController,
  type NotificationSession,
  type NotificationSettings,
  type NotificationSoundEvent,
} from "./notification-controller"
import { createPermissionPrompt, type PermissionPrompt, type PromptStorage } from "./permission"
import type { ViewingChannel } from "./viewing"

export type AttachNotificationsOptions = {
  /** `AccountSession`. */
  readonly session: NotificationSession & { readonly badgeCount: ReadSignal<number> }
  readonly platform: Pick<Platform, "notifications" | "badge" | "lifecycle">
  /** `AppRuntime.role`. Omitted or `undefined`: this context is the only one and shows notifications. */
  readonly role?: ReadSignal<CoreRole | undefined>
  /** Wall clock in milliseconds since the epoch. */
  readonly clock: { now(): number }
  /** Remembers that the user dismissed the "Turn on notifications" affordance (`localStorage`). */
  readonly storage?: PromptStorage
  /**
   * A channel shared by the account's contexts (a `BroadcastChannel`), so the
   * leader does not notify for a chat the user is reading in another tab.
   * Closed on dispose when it has `close`.
   */
  readonly channel?: ViewingChannel & { close?(): void }
  readonly contextId?: string
  readonly settings?: NotificationSettings
  /** The user's badge setting. Default on. */
  readonly badgeEnabled?: ReadSignal<boolean>
  /** Hook for notification sounds (Phase 3). */
  readonly onSound?: (event: NotificationSoundEvent) => void
}

/** Call it to detach; `prompt` and `controller` are there while attached. */
export type NotificationsAttachment = Dispose & {
  readonly prompt: PermissionPrompt
  readonly controller: NotificationController
  readonly dispose: Dispose
}

export const attachNotifications = (options: AttachNotificationsOptions): NotificationsAttachment => {
  const { session, platform } = options
  const stopBadge = attachBadge({
    count: session.badgeCount,
    badge: platform.badge,
    ...(options.badgeEnabled ? { enabled: options.badgeEnabled } : {}),
  })
  const controller = createNotificationController({
    session,
    notifications: platform.notifications,
    lifecycle: platform.lifecycle,
    clock: options.clock,
    ...(options.role ? { role: options.role } : {}),
    ...(options.channel ? { channel: options.channel } : {}),
    ...(options.contextId !== undefined ? { contextId: options.contextId } : {}),
    ...(options.settings ? { settings: options.settings } : {}),
    ...(options.onSound ? { onSound: options.onSound } : {}),
  })
  const prompt = createPermissionPrompt({
    notifications: platform.notifications,
    ...(options.storage ? { storage: options.storage } : {}),
  })

  let disposed = false
  const dispose = () => {
    if (disposed) return
    disposed = true
    controller.dispose()
    stopBadge()
    try {
      options.channel?.close?.()
    } catch {
      // Already closed.
    }
  }
  return Object.assign(dispose, { prompt, controller, dispose })
}
