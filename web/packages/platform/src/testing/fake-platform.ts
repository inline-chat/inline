/**
 * A `Platform` for other packages' tests. It records what the app asked for
 * (notifications, badge values, opened links, saved files) and lets a test
 * drive what the app observes (permission, visibility, focus, online state,
 * time and sleep). The badge and wake rules are the real ones, on a manual
 * clock.
 */

import { batch, signal, type Dispose } from "@inline/reactive"
import { available, DESKTOP_ONLY, unavailable } from "../capability"
import { createBadgeController } from "../badge-policy"
import { isUserGesture } from "../gesture"
import type {
  FreezeEvent,
  NotificationActionEvent,
  NotificationClick,
  NotificationData,
  NotificationPermissionState,
  NotificationRequest,
  Notifications,
  OperatingSystem,
  PageHideEvent,
  Platform,
  SaveOutcome,
  StorageEstimate,
  TitleBarInsets,
  TrayChat,
  WakeEvent,
} from "../platform"
import { createUpdateFeed, type UpdateFeed } from "../update-feed"
import { createWakeDetector } from "../wake-detector"
import { manualClock, type ManualClock } from "./manual-clock"

export interface FakePlatformOptions {
  /** `true` makes a fake Electron platform: desktop capabilities available and recorded. */
  readonly desktop?: boolean
  readonly os?: OperatingSystem
  readonly clock?: ManualClock
  /** Set to false for a context without notifications. */
  readonly notificationsAvailable?: boolean
  readonly notificationPermission?: NotificationPermissionState
  /** What a permission prompt answers. Defaults to `granted`. */
  readonly permissionAnswer?: NotificationPermissionState
  /** Defaults to http, https and mailto. */
  readonly isSafeExternalUrl?: (url: string) => boolean
  readonly initialDeepLink?: string | null
  readonly visible?: boolean
  readonly focused?: boolean
  readonly online?: boolean
  readonly saveOutcome?: SaveOutcome
  readonly persisted?: boolean
  readonly title?: string
  readonly wakeIntervalMs?: number
  readonly wakeToleranceMs?: number
}

export interface FakePlatform {
  readonly platform: Platform
  readonly clock: ManualClock
  readonly notifications: {
    /** Every notification shown, in order. */
    readonly shown: readonly NotificationRequest[]
    /** Tags shown and not yet closed or clicked. */
    openTags(): string[]
    readonly closedTags: readonly string[]
    readonly permissionRequests: number
    setPermission(state: NotificationPermissionState): void
    /** The user clicks a notification that is open. Throws if it is not. */
    click(tag: string): void
    action(tag: string, actionId: string, reply?: string): void
  }
  readonly badge: {
    /** Every count that reached the screen, in order. */
    readonly applied: readonly number[]
  }
  readonly links: {
    readonly opened: readonly string[]
    readonly refused: readonly string[]
    deliver(url: string): void
  }
  readonly files: {
    readonly saved: readonly { readonly name: string; readonly blob: Blob }[]
    readonly revealed: readonly string[]
  }
  readonly lifecycle: {
    setVisible(visible: boolean): void
    setFocused(focused: boolean): void
    setOnline(online: boolean): void
    freeze(): void
    resume(): void
    pageHide(persisted: boolean): void
  }
  readonly desktop: {
    readonly windowsOpened: readonly (string | undefined)[]
    readonly trayChats: readonly (readonly TrayChat[])[]
    selectTray(data: NotificationData): void
    setTitleBarInsets(insets: TitleBarInsets): void
  }
  readonly updates: UpdateFeed
  /** How many times `updater.apply` reached the apply handler. */
  readonly appliedUpdates: number
  setStorageEstimate(estimate: StorageEstimate): void
  dispose(): void
}

const defaultSafeUrl = (url: string): boolean => /^(https?:|mailto:)/i.test(url)

export const createFakePlatform = (options: FakePlatformOptions = {}): FakePlatform => {
  const clock = options.clock ?? manualClock()
  const desktop = options.desktop === true
  const os = options.os ?? "mac"
  const listeners = <E>() => {
    const set = new Set<(event: E) => void>()
    return {
      add(listener: (event: E) => void): Dispose {
        set.add(listener)
        return () => set.delete(listener)
      },
      emit(event: E) {
        for (const listener of Array.from(set)) listener(event)
      },
    }
  }

  // notifications
  const permission = signal<NotificationPermissionState>(options.notificationPermission ?? "granted")
  const shown: NotificationRequest[] = []
  const open = new Map<string, NotificationRequest>()
  const shownTags = new Set<string>()
  const closedTags: string[] = []
  let permissionRequests = 0
  const clicks = listeners<NotificationClick>()
  const actions = listeners<NotificationActionEvent>()
  const close = (tag: string) => {
    if (!open.delete(tag)) return
    closedTags.push(tag)
  }
  const notifications: Notifications = {
    permission,
    async requestPermission(gesture) {
      if (!isUserGesture(gesture) || permission.peek() !== "default") return permission.peek()
      permissionRequests++
      permission.set(options.permissionAnswer ?? "granted")
      return permission.peek()
    },
    show(request) {
      if (permission.peek() !== "granted" || shownTags.has(request.tag)) return false
      shownTags.add(request.tag)
      shown.push(request)
      open.set(request.tag, request)
      return true
    },
    close,
    closeWhere(match) {
      for (const [tag, request] of Array.from(open)) if (match(request.data)) close(tag)
    },
    onClick: clicks.add,
    onAction: actions.add,
    supportsActions: desktop,
    supportsInlineReply: desktop && os !== "linux",
  }

  // badge and title
  const badgeCount = signal(0)
  const applied: number[] = []
  const badgeController = createBadgeController({
    clock,
    apply: (count) => {
      applied.push(count)
      badgeCount.set(count)
    },
  })
  const title = signal(options.title ?? "Inline")

  // links
  const opened: string[] = []
  const refused: string[] = []
  const deepLinks = listeners<string>()
  const isSafe = options.isSafeExternalUrl ?? defaultSafeUrl

  // files
  const saved: { name: string; blob: Blob }[] = []
  const revealed: string[] = []

  // storage
  const persisted = signal<boolean | null>(options.persisted ?? false)
  const estimate = signal<StorageEstimate | null>(null)

  // lifecycle
  const visible = signal(options.visible ?? true)
  const focused = signal(options.focused ?? true)
  const online = signal(options.online ?? true)
  const freezes = listeners<FreezeEvent>()
  const pageHides = listeners<PageHideEvent>()
  const wakes = listeners<WakeEvent>()
  const wakeDetector = createWakeDetector({
    clock,
    onWake: (gapMs) => wakes.emit({ gapMs }),
    ...(options.wakeIntervalMs !== undefined ? { intervalMs: options.wakeIntervalMs } : {}),
    ...(options.wakeToleranceMs !== undefined ? { toleranceMs: options.wakeToleranceMs } : {}),
  })

  // updater
  const { updater, feed } = createUpdateFeed()
  let appliedUpdates = 0
  feed.setApplyHandler(() => {
    appliedUpdates++
  })

  // desktop
  const windowsOpened: (string | undefined)[] = []
  const trayChats: (readonly TrayChat[])[] = []
  const traySelects = listeners<NotificationData>()
  const alwaysOnTop = signal(false)
  const insets = signal<TitleBarInsets>({ left: 0, right: 138, height: 32 })
  const spellcheck = signal(true)
  const launchAtLogin = signal(false)
  const accelerator = signal<string | null>(null)

  const platform: Platform = {
    info: {
      kind: desktop ? "electron" : "web",
      os,
      shortcutModifier: os === "mac" || os === "ios" ? "meta" : "ctrl",
      surface: desktop ? "window" : "tab",
    },
    notifications: options.notificationsAvailable === false ? unavailable("no-notification-api") : available(notifications),
    badge: {
      set: (count, setOptions) => badgeController.set(count, setOptions?.immediate === true),
      count: badgeCount,
    },
    links: {
      openExternal(url) {
        if (!isSafe(url)) {
          refused.push(url)
          return false
        }
        opened.push(url)
        return true
      },
      initialDeepLink: options.initialDeepLink ?? null,
      onDeepLink: deepLinks.add,
    },
    files: {
      async save(blob, name) {
        const outcome = options.saveOutcome ?? (desktop ? "saved" : "downloaded")
        if (outcome === "saved" || outcome === "downloaded") saved.push({ name, blob })
        return outcome
      },
      reveal: desktop ? available({ reveal: (path: string) => void revealed.push(path) }) : unavailable(DESKTOP_ONLY),
    },
    storage: available({
      persisted,
      estimate,
      canRequestSilently: true,
      async requestPersistence() {
        return persisted.peek() === true
      },
      async refreshEstimate() {},
    }),
    lifecycle: {
      visible,
      focused,
      online,
      freezes: { subscribe: freezes.add },
      onPageHide: pageHides.add,
      onWake: wakes.add,
    },
    window: {
      setTitle: (next) => title.set(next),
      title,
      newWindow: desktop ? available({ open: (path?: string) => void windowsOpened.push(path) }) : unavailable(DESKTOP_ONLY),
      alwaysOnTop: desktop
        ? available({ value: alwaysOnTop, set: (on: boolean) => alwaysOnTop.set(on) })
        : unavailable(DESKTOP_ONLY),
      titleBarOverlay: desktop && os !== "mac" ? available({ insets }) : unavailable(DESKTOP_ONLY),
    },
    updater,
    spellcheck: desktop
      ? available({ enabled: spellcheck, setEnabled: (on: boolean) => spellcheck.set(on) })
      : unavailable(DESKTOP_ONLY),
    tray: desktop
      ? available({
          setUnreadChats: (chats: readonly TrayChat[]) => void trayChats.push(chats),
          onSelect: traySelects.add,
        })
      : unavailable(DESKTOP_ONLY),
    launchAtLogin: desktop
      ? available({ enabled: launchAtLogin, set: async (on: boolean) => launchAtLogin.set(on) })
      : unavailable(DESKTOP_ONLY),
    globalShortcut: desktop
      ? available({
          accelerator,
          set: async (next: string | null) => {
            accelerator.set(next)
            return true
          },
        })
      : unavailable(DESKTOP_ONLY),
  }

  let frozen = false
  return {
    platform,
    clock,
    notifications: {
      shown,
      openTags: () => [...open.keys()],
      closedTags,
      get permissionRequests() {
        return permissionRequests
      },
      setPermission: (state) => permission.set(state),
      click(tag) {
        const request = open.get(tag)
        if (!request) throw new Error(`no open notification with tag ${tag}`)
        close(tag)
        clicks.emit({ tag, data: request.data })
      },
      action(tag, actionId, reply) {
        const request = open.get(tag)
        if (!request) throw new Error(`no open notification with tag ${tag}`)
        if (!notifications.supportsActions) throw new Error("actions are not supported on this fake platform")
        close(tag)
        actions.emit({ tag, data: request.data, actionId, ...(reply !== undefined ? { reply } : {}) })
      },
    },
    badge: { applied },
    links: { opened, refused, deliver: deepLinks.emit },
    files: { saved, revealed },
    lifecycle: {
      setVisible(next) {
        batch(() => {
          visible.set(next)
          if (!next) focused.set(false)
        })
        if (next) wakeDetector.check()
      },
      setFocused(next) {
        focused.set(next)
        if (next) wakeDetector.check()
      },
      setOnline(next) {
        online.set(next)
        if (next) wakeDetector.check()
      },
      freeze() {
        if (frozen) return
        frozen = true
        freezes.emit("freeze")
      },
      resume() {
        if (!frozen) return
        frozen = false
        freezes.emit("resume")
      },
      pageHide(persistedHide) {
        pageHides.emit({ persisted: persistedHide })
        if (persistedHide && !frozen) {
          frozen = true
          freezes.emit("freeze")
        }
      },
    },
    desktop: {
      windowsOpened,
      trayChats,
      selectTray: traySelects.emit,
      setTitleBarInsets: (next) => insets.set(next),
    },
    updates: feed,
    get appliedUpdates() {
      return appliedUpdates
    },
    setStorageEstimate: (next) => estimate.set(next),
    dispose() {
      badgeController.dispose()
      wakeDetector.dispose()
    },
  }
}
