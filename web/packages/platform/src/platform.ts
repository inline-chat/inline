/**
 * The platform interface. App code asks the platform for a capability; it
 * never checks whether it runs in a browser or in Electron. Each capability
 * is available or explicitly unavailable (`Capability<T>`), so a caller can
 * hide a feature instead of failing.
 *
 * Implementations: `createWebPlatform` (src/web), the Electron one over the
 * preload bridge (`DesktopBridge`, later), and `createFakePlatform`
 * (src/testing) for other packages' tests.
 */

import type { Dispose, ReadSignal } from "@inline/reactive"
import type { Capability } from "./capability"
import type { UserGesture } from "./gesture"

// ---------------------------------------------------------------------------
// info

export type PlatformKind = "web" | "electron"

export type OperatingSystem = "mac" | "windows" | "linux" | "chromeos" | "ios" | "android" | "unknown"

export interface PlatformInfo {
  readonly kind: PlatformKind
  readonly os: OperatingSystem
  /** The primary shortcut modifier: Cmd on Apple systems, Ctrl elsewhere. */
  readonly shortcutModifier: "meta" | "ctrl"
  /**
   * `tab`: a browser tab, where the browser keeps some shortcuts (new window,
   * new tab, close, tab switching by number). `window`: an app window that can
   * bind them. The command registry picks its shortcut set from this.
   */
  readonly surface: "tab" | "window"
}

// ---------------------------------------------------------------------------
// notifications

export type NotificationPermissionState = "default" | "granted" | "denied"

/**
 * Plain, structured-cloneable data that identifies where a click goes: for
 * a message, `{ chatId, messageId }` as strings. It crosses the preload
 * bridge and may later cross a service worker, so no functions or objects.
 */
export type NotificationData = { readonly [key: string]: string | number | boolean | null }

export interface NotificationAction {
  readonly id: string
  readonly title: string
}

export interface NotificationRequest {
  /**
   * Stable identity, one per message (`messageNotificationTag`). Showing a
   * tag again replaces the earlier notification instead of adding one, and an
   * implementation ignores a tag it already showed in this context.
   */
  readonly tag: string
  readonly title: string
  readonly body?: string
  /** Conversation key (`chatNotificationGroup`) for OS grouping where supported. */
  readonly group?: string
  /** Image URL (an avatar). Must be same-origin or from the media origin. */
  readonly icon?: string
  /** No sound or vibration. */
  readonly silent?: boolean
  /** An urgent nudge: stays until dismissed where the system allows it. */
  readonly urgent?: boolean
  /** Ignored unless `supportsActions`. */
  readonly actions?: readonly NotificationAction[]
  readonly data: NotificationData
}

export interface NotificationClick {
  readonly tag: string
  readonly data: NotificationData
}

export interface NotificationActionEvent extends NotificationClick {
  readonly actionId: string
  /** Text typed into an inline reply, where `supportsInlineReply`. */
  readonly reply?: string
}

export interface Notifications {
  readonly permission: ReadSignal<NotificationPermissionState>
  /**
   * Ask for permission. Takes a `UserGesture` from `userGesture(event)` so it
   * can only be called from a click or key handler: browsers ignore or
   * penalize prompts without one. Resolves to the resulting state; with an
   * invalid gesture it does not prompt and resolves to the current state.
   */
  requestPermission(gesture: UserGesture): Promise<NotificationPermissionState>
  /** Shows it if permission is granted. Returns whether it was shown. */
  show(request: NotificationRequest): boolean
  close(tag: string): void
  /** Close every open notification whose data matches, e.g. one chat's on read. */
  closeWhere(match: (data: NotificationData) => boolean): void
  /** A click on the notification body. The window is focused before this runs. */
  onClick(listener: (click: NotificationClick) => void): Dispose
  /** An action button or inline reply. Never fires where unsupported. */
  onAction(listener: (event: NotificationActionEvent) => void): Dispose
  /**
   * Action buttons: Electron on Windows and macOS; Linux only when the
   * notification server supports them; never for page notifications on the web.
   */
  readonly supportsActions: boolean
  /** Inline reply: Electron on macOS and Windows; not on Linux or the web. */
  readonly supportsInlineReply: boolean
}

// ---------------------------------------------------------------------------
// badge

export interface BadgeSetOptions {
  /** Skip the increase debounce: sign-in, sign-out, re-enabling the badge. */
  readonly immediate?: boolean
}

export interface Badge {
  /**
   * The count of prominent unread chats (feature-map rule 9). Decreases show
   * at once, increases after 500 ms (`createBadgeController`).
   */
  set(count: number, options?: BadgeSetOptions): void
  /** The count on display now. */
  readonly count: ReadSignal<number>
}

// ---------------------------------------------------------------------------
// links

export interface Links {
  /**
   * Open a URL outside the app: a new browser context with
   * `noopener,noreferrer`, or the system browser in Electron. Every URL passes
   * the injected safety check first. Returns false when it was refused.
   */
  openExternal(url: string): boolean
  /**
   * The link the app was started with: the page URL in a browser, an
   * `inline://` URL in Electron when launched from one, otherwise null.
   */
  readonly initialDeepLink: string | null
  /** Links that arrive while running: a second Electron launch forwards its link. Never fires on the web. */
  onDeepLink(listener: (url: string) => void): Dispose
}

// ---------------------------------------------------------------------------
// files

export type SaveOutcome =
  /** Written through a save dialog. */
  | "saved"
  /** Handed to the browser's download manager; the result is not observable. */
  | "downloaded"
  | "cancelled"
  | "failed"

export interface Files {
  /**
   * Save a blob under a suggested name. Call from a user gesture: the save
   * dialog needs one. Resolves when the dialog closes or the download starts.
   */
  save(blob: Blob, suggestedName: string): Promise<SaveOutcome>
  /** Show a saved file in the system file manager. Desktop only. */
  readonly reveal: Capability<{ reveal(path: string): void }>
}

// ---------------------------------------------------------------------------
// storage

export interface StorageEstimate {
  readonly usage: number
  readonly quota: number
}

export interface PersistentStorage {
  /** Whether the origin's storage is exempt from eviction. Null until known or where unsupported. */
  readonly persisted: ReadSignal<boolean | null>
  readonly estimate: ReadSignal<StorageEstimate | null>
  /**
   * Whether `requestPersistence` can ask without showing a prompt. False in
   * Firefox, which prompts.
   */
  readonly canRequestSilently: boolean
  /**
   * Ask for persistence where the browser decides without a prompt; elsewhere
   * report the current state without asking. Resolves to the persisted state.
   */
  requestPersistence(): Promise<boolean>
  refreshEstimate(): Promise<void>
}

// ---------------------------------------------------------------------------
// lifecycle

export type FreezeEvent = "freeze" | "resume"

/** Same shape as `LifecycleSource` in `@inline/link`, so it can be passed straight to it. */
export interface FreezeSource {
  subscribe(listener: (event: FreezeEvent) => void): Dispose
}

export interface PageHideEvent {
  /** True when the page goes into the back-forward cache and may come back. */
  readonly persisted: boolean
}

export interface WakeEvent {
  /** The timer gap that revealed the sleep, in milliseconds. */
  readonly gapMs: number
}

export interface Lifecycle {
  readonly visible: ReadSignal<boolean>
  readonly focused: ReadSignal<boolean>
  readonly online: ReadSignal<boolean>
  /** Freeze and resume, including the back-forward cache. */
  readonly freezes: FreezeSource
  onPageHide(listener: (event: PageHideEvent) => void): Dispose
  /** The machine slept: a timer fired much later than scheduled. */
  onWake(listener: (event: WakeEvent) => void): Dispose
}

// ---------------------------------------------------------------------------
// window

export interface TitleBarInsets {
  readonly left: number
  readonly right: number
  readonly height: number
}

export interface WindowChrome {
  /** The base title. The badge adds its own prefix on the web. */
  setTitle(title: string): void
  readonly title: ReadSignal<string>
  readonly newWindow: Capability<{ open(path?: string): void }>
  readonly alwaysOnTop: Capability<{ readonly value: ReadSignal<boolean>; set(on: boolean): void }>
  /** The native window controls drawn over our toolbar on Windows and Linux. */
  readonly titleBarOverlay: Capability<{ readonly insets: ReadSignal<TitleBarInsets> }>
}

// ---------------------------------------------------------------------------
// updater

export type UpdateState =
  | { readonly status: "none" }
  | { readonly status: "available"; readonly version?: string }
  | { readonly status: "ready"; readonly version?: string }

export interface Updater {
  readonly state: ReadSignal<UpdateState>
  /** Restart into the ready version. Does nothing unless the state is `ready`. */
  apply(): void
}

// ---------------------------------------------------------------------------
// desktop-only

export interface Spellcheck {
  readonly enabled: ReadSignal<boolean>
  setEnabled(on: boolean): void
}

export interface TrayChat {
  readonly title: string
  readonly data: NotificationData
}

export interface Tray {
  /** The tray menu's list of unread chats. */
  setUnreadChats(chats: readonly TrayChat[]): void
  onSelect(listener: (data: NotificationData) => void): Dispose
}

export interface LaunchAtLogin {
  readonly enabled: ReadSignal<boolean>
  set(on: boolean): Promise<void>
}

export interface GlobalShortcut {
  /** The "Focus Inline" accelerator, user-set, or null. */
  readonly accelerator: ReadSignal<string | null>
  /** Resolves false when the system refuses it (taken by another app). */
  set(accelerator: string | null): Promise<boolean>
}

// ---------------------------------------------------------------------------

export interface Platform {
  readonly info: PlatformInfo
  readonly notifications: Capability<Notifications>
  readonly badge: Badge
  readonly links: Links
  readonly files: Files
  readonly storage: Capability<PersistentStorage>
  readonly lifecycle: Lifecycle
  readonly window: WindowChrome
  readonly updater: Updater
  readonly spellcheck: Capability<Spellcheck>
  readonly tray: Capability<Tray>
  readonly launchAtLogin: Capability<LaunchAtLogin>
  readonly globalShortcut: Capability<GlobalShortcut>
}
