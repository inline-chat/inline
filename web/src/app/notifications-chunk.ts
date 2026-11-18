/**
 * Message notifications and the unread badge for a session: the part of
 * `attachNotifications` (`features/notifications`) the first frame does not
 * need. Loaded on the idle lane after the first paint (`boot.ts`). The
 * permission prompt is made at once instead (the "Turn on notifications"
 * banner is on the first frame, so it must not appear later and move the
 * panes).
 *
 * Nothing is missed by attaching a moment late: the controller's source is
 * the core's `newMessages` query, a list of the last two minutes' incoming
 * messages, not an event stream; the badge is set from the current count.
 */

import type { Dispose } from "@inline/reactive"
import { attachBadge, createNotificationController, type AttachNotificationsOptions } from "../features/notifications"

export type MessageNotificationsOptions = Omit<AttachNotificationsOptions, "storage">

export const attachMessageNotifications = (options: MessageNotificationsOptions): Dispose => {
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
  return () => {
    controller.dispose()
    stopBadge()
    try {
      options.channel?.close?.()
    } catch {
      // Already closed.
    }
  }
}

export type NotificationsChunk = typeof import("./notifications-chunk")
