/**
 * Page notifications (`new Notification`). No action buttons or inline reply:
 * those need a service worker registration's `showNotification`, which only
 * some browsers honor; the flags say so and `onAction` never fires.
 *
 * Identity: one tag per message. The browser replaces a notification with the
 * same tag; on top of that a tag already shown in this context is ignored, so
 * a replayed update cannot notify twice. Cross-tab de-duplication is the
 * caller's job (only the leader shows notifications, package 2H).
 */

import type { Dispose } from "@inline/reactive"
import { signal } from "@inline/reactive"
import { available, unavailable, type Capability } from "../capability"
import { isUserGesture } from "../gesture"
import type {
  NotificationActionEvent,
  NotificationClick,
  NotificationData,
  NotificationPermissionState,
  Notifications,
} from "../platform"
import { toPermissionState, type PageNotificationLike, type PermissionStatusLike, type WebEnv } from "./env"

/** How many tags a context remembers for de-duplication. */
export const SHOWN_TAG_MEMORY = 500

export interface WebNotifications {
  readonly capability: Capability<Notifications>
  dispose(): void
}

export const createWebNotifications = (env: WebEnv): WebNotifications => {
  const api = env.Notification
  if (!api) {
    return { capability: unavailable("no-notification-api"), dispose: () => {} }
  }

  const permission = signal<NotificationPermissionState>(toPermissionState(api.permission))
  const open = new Map<string, { notification: PageNotificationLike; data: NotificationData }>()
  const shownTags = new Set<string>()
  const clickListeners = new Set<(click: NotificationClick) => void>()
  let disposed = false

  // Follow changes the user makes in browser settings, where supported.
  let status: PermissionStatusLike | null = null
  const onStatusChange = () => {
    // The Permissions API says "prompt" where Notification says "default".
    permission.set(toPermissionState(api.permission))
  }
  try {
    void env.navigator.permissions
      ?.query({ name: "notifications" })
      .then((result) => {
        if (disposed) return
        status = result
        result.addEventListener("change", onStatusChange)
      })
      .catch(() => {})
  } catch {
    // Permissions API missing or the name unsupported.
  }

  const remember = (tag: string) => {
    shownTags.add(tag)
    if (shownTags.size <= SHOWN_TAG_MEMORY) return
    const oldest = shownTags.values().next()
    if (!oldest.done) shownTags.delete(oldest.value)
  }

  const close = (tag: string) => {
    const entry = open.get(tag)
    if (!entry) return
    open.delete(tag)
    try {
      entry.notification.close()
    } catch {
      // Already gone.
    }
  }

  const notifications: Notifications = {
    permission,
    async requestPermission(gesture) {
      const current = toPermissionState(api.permission)
      if (!isUserGesture(gesture) || current !== "default") {
        permission.set(current)
        return current
      }
      try {
        const result = toPermissionState(await api.requestPermission())
        permission.set(result)
        return result
      } catch {
        const result = toPermissionState(api.permission)
        permission.set(result)
        return result
      }
    },
    show(request) {
      if (disposed) return false
      if (toPermissionState(api.permission) !== "granted") return false
      if (shownTags.has(request.tag)) return false
      let notification: PageNotificationLike
      try {
        notification = new api(request.title, {
          tag: request.tag,
          ...(request.body !== undefined ? { body: request.body } : {}),
          ...(request.icon !== undefined ? { icon: request.icon } : {}),
          ...(request.silent ? { silent: true } : {}),
          ...(request.urgent ? { requireInteraction: true } : {}),
        })
      } catch {
        // Chrome on Android throws: page notifications need a service worker there.
        return false
      }
      remember(request.tag)
      const data = request.data
      open.set(request.tag, { notification, data })
      notification.onclick = () => {
        try {
          env.window.focus()
        } catch {
          // Focus is best effort.
        }
        close(request.tag)
        for (const listener of Array.from(clickListeners)) listener({ tag: request.tag, data })
      }
      notification.onclose = () => {
        if (open.get(request.tag)?.notification === notification) open.delete(request.tag)
      }
      return true
    },
    close,
    closeWhere(match) {
      for (const [tag, entry] of Array.from(open)) if (match(entry.data)) close(tag)
    },
    onClick(listener) {
      clickListeners.add(listener)
      return () => clickListeners.delete(listener)
    },
    onAction(_listener: (event: NotificationActionEvent) => void): Dispose {
      return () => {}
    },
    supportsActions: false,
    supportsInlineReply: false,
  }

  return {
    capability: available(notifications),
    dispose() {
      disposed = true
      status?.removeEventListener("change", onStatusChange)
      clickListeners.clear()
    },
  }
}
