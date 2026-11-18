/**
 * The web implementation of `Platform`, over an injected `window`,
 * `document` and `navigator` (`WebEnv`). Defaults to the real globals, read
 * when `createWebPlatform` is called, never at import.
 */

import { DESKTOP_ONLY, unavailable } from "../capability"
import type { Platform } from "../platform"
import { createUpdateFeed, type UpdateFeed } from "../update-feed"
import { createWebTitleAndBadge } from "./badge"
import { webEnvFromGlobals, type WebEnv } from "./env"
import { createWebFiles } from "./files"
import { webPlatformInfo } from "./info"
import { createWebLifecycle, type WebLifecycleOptions } from "./lifecycle"
import { createWebLinks, type ExternalUrlCheck } from "./links"
import { createWebNotifications } from "./notifications"
import { createWebStorage } from "./storage"

export interface WebPlatformOptions extends WebLifecycleOptions {
  /** Required: the link-scheme allowlist from `chat-ui`. */
  readonly isSafeExternalUrl: ExternalUrlCheck
  /** Defaults to `webEnvFromGlobals()`. */
  readonly env?: WebEnv
}

export interface WebPlatform extends Platform {
  /** Where the service worker glue reports update state and installs `apply`. */
  readonly updates: UpdateFeed
  /** Remove listeners and timers. The page title and favicon are restored. */
  dispose(): void
}

export const createWebPlatform = (options: WebPlatformOptions): WebPlatform => {
  const env = options.env ?? webEnvFromGlobals()
  const titleAndBadge = createWebTitleAndBadge(env)
  const notifications = createWebNotifications(env)
  const lifecycle = createWebLifecycle(env, options)
  const { updater, feed } = createUpdateFeed()

  return {
    info: webPlatformInfo(env.navigator),
    notifications: notifications.capability,
    badge: titleAndBadge.badge,
    links: createWebLinks(env, options.isSafeExternalUrl),
    files: createWebFiles(env),
    storage: createWebStorage(env),
    lifecycle: lifecycle.lifecycle,
    window: {
      setTitle: titleAndBadge.setTitle,
      title: titleAndBadge.title,
      newWindow: unavailable(DESKTOP_ONLY),
      alwaysOnTop: unavailable(DESKTOP_ONLY),
      titleBarOverlay: unavailable(DESKTOP_ONLY),
    },
    updater,
    updates: feed,
    spellcheck: unavailable(DESKTOP_ONLY),
    tray: unavailable(DESKTOP_ONLY),
    launchAtLogin: unavailable(DESKTOP_ONLY),
    globalShortcut: unavailable(DESKTOP_ONLY),
    dispose() {
      titleAndBadge.dispose()
      notifications.dispose()
      lifecycle.dispose()
    },
  }
}
