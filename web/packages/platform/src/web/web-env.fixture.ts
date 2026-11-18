/**
 * A `WebEnv` for tests under happy-dom: the real happy-dom `window` and
 * `document` (with visibility and focus made controllable), and small fakes
 * for what happy-dom lacks (notifications, storage, permissions, the badging
 * API, object URLs, canvas). Time is a manual clock.
 */

import { manualClock, type ManualClock } from "../testing/manual-clock"
import type {
  NotificationApiLike,
  PageNotificationOptions,
  PermissionStatusLike,
  WebDocumentLike,
  WebEnv,
  WebNavigatorLike,
  WebWindowLike,
} from "./env"
import type { FaviconRenderer } from "./favicon"

export const CHROME_UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
export const FIREFOX_UA = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"

export class FakePermissionStatus extends EventTarget implements PermissionStatusLike {
  constructor(public state: string) {
    super()
  }
  change(state: string) {
    this.state = state
    this.dispatchEvent(new Event("change"))
  }
}

export interface FakeNotificationInstance {
  readonly title: string
  readonly options?: PageNotificationOptions | undefined
  onclick: ((event: unknown) => void) | null
  onclose: ((event: unknown) => void) | null
  closed: boolean
  close(): void
}

export const fakeNotificationApi = (initial = "default") => {
  const state = { permission: initial, answer: "granted", requests: 0, throwOnCreate: false }
  const instances: FakeNotificationInstance[] = []
  class FakeNotification implements FakeNotificationInstance {
    onclick: ((event: unknown) => void) | null = null
    onclose: ((event: unknown) => void) | null = null
    closed = false
    static get permission() {
      return state.permission
    }
    static async requestPermission() {
      state.requests++
      state.permission = state.answer
      return state.permission
    }
    constructor(
      readonly title: string,
      readonly options?: PageNotificationOptions,
    ) {
      if (state.throwOnCreate) throw new TypeError("Illegal constructor")
      instances.push(this)
    }
    close() {
      if (this.closed) return
      this.closed = true
      this.onclose?.({})
    }
  }
  return { api: FakeNotification as unknown as NotificationApiLike, state, instances }
}

export const deferredFavicon = () => {
  const calls: { base: string; label: string; resolve: (url: string | null) => void }[] = []
  const renderer: FaviconRenderer = {
    render: (base, label) =>
      new Promise((resolve) => {
        calls.push({ base, label, resolve })
      }),
  }
  return { renderer, calls }
}

export const immediateFavicon: FaviconRenderer = {
  render: async (_base, label) => `data:image/png;label=${label}`,
}

export interface TestEnv {
  readonly env: WebEnv
  readonly clock: ManualClock
  readonly navigator: WebNavigatorLike & {
    userAgent: string
    onLine: boolean
    badgeCalls: (number | "clear")[]
  }
  readonly opened: { url: string; target: string; features: string }[]
  readonly focusCalls: { count: number }
  readonly revoked: string[]
  readonly notifications: ReturnType<typeof fakeNotificationApi>
  readonly permissionStatus: FakePermissionStatus
  setVisibility(state: "visible" | "hidden"): void
  setHasFocus(focus: boolean): void
}

export const makeTestEnv = (
  options: {
    userAgent?: string
    favicon?: FaviconRenderer | null
    notifications?: boolean
    notificationPermission?: string
    storage?: WebNavigatorLike["storage"] | null
  } = {},
): TestEnv => {
  const clock = manualClock()
  const doc = document as unknown as WebDocumentLike & { hasFocus(): boolean }
  let visibility = "visible"
  let hasFocus = true
  Object.defineProperty(document, "visibilityState", { configurable: true, get: () => visibility })
  Object.defineProperty(document, "hasFocus", { configurable: true, value: () => hasFocus })

  const opened: { url: string; target: string; features: string }[] = []
  const focusCalls = { count: 0 }
  const win = window as unknown as WebWindowLike
  Object.defineProperty(window, "open", {
    configurable: true,
    value: (url: string, target: string, features: string) => {
      opened.push({ url, target, features })
      return null
    },
  })
  Object.defineProperty(window, "focus", { configurable: true, value: () => focusCalls.count++ })

  const permissionStatus = new FakePermissionStatus(options.notificationPermission ?? "default")
  const badgeCalls: (number | "clear")[] = []
  const nav = {
    userAgent: options.userAgent ?? CHROME_UA,
    onLine: true,
    badgeCalls,
    ...(options.storage === null ? {} : { storage: options.storage ?? {} }),
    permissions: { query: async () => permissionStatus },
    setAppBadge: async (count?: number) => {
      badgeCalls.push(count ?? 0)
    },
    clearAppBadge: async () => {
      badgeCalls.push("clear")
    },
  }

  const notifications = fakeNotificationApi(options.notificationPermission ?? "default")
  const revoked: string[] = []
  let urlCount = 0
  const env: WebEnv = {
    window: win,
    document: doc,
    navigator: nav,
    ...(options.notifications === false ? {} : { Notification: notifications.api }),
    URL: {
      createObjectURL: () => `blob:test/${++urlCount}`,
      revokeObjectURL: (url) => void revoked.push(url),
    },
    clock,
    favicon: options.favicon === undefined ? immediateFavicon : options.favicon,
  }

  return {
    env,
    clock,
    navigator: nav,
    opened,
    focusCalls,
    revoked,
    notifications,
    permissionStatus,
    setVisibility(state) {
      visibility = state
      document.dispatchEvent(new Event("visibilitychange"))
    },
    setHasFocus(focus) {
      hasFocus = focus
    },
  }
}

/** Let promise callbacks run. */
export const flush = async () => {
  for (let i = 0; i < 5; i++) await Promise.resolve()
}
