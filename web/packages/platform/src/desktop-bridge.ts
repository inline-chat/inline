/**
 * What the Electron preload must expose for the Electron implementation of
 * `Platform` (package 4B/4C). Types only: no Electron code lives here.
 *
 * Rules: every call is a named method with plain, validated arguments; there
 * is no generic `invoke(channel, ...args)`. Policy (badge debounce,
 * notification rules, URL safety) stays in shared code; the bridge only
 * performs the native effect. The main process validates arguments and the
 * sender again, since a compromised renderer can call the bridge directly.
 */

import type {
  NotificationActionEvent,
  NotificationClick,
  NotificationData,
  NotificationPermissionState,
  NotificationRequest,
  OperatingSystem,
  TitleBarInsets,
  TrayChat,
  UpdateState,
} from "./platform"

type Unsubscribe = () => void

export interface DesktopBridge {
  // info
  readonly os: Exclude<OperatingSystem, "ios" | "android" | "chromeos" | "unknown">
  /** The `inline://` URL the app was launched with, if any. */
  readonly initialDeepLink: string | null

  // notifications
  notificationPermission(): NotificationPermissionState
  /** Called only behind a `UserGesture` check in shared code. */
  requestNotificationPermission(): Promise<NotificationPermissionState>
  /** Main shows it with the tag as its identity; false when the OS refused. */
  showNotification(request: NotificationRequest): boolean
  closeNotification(tag: string): void
  onNotificationClick(listener: (click: NotificationClick) => void): Unsubscribe
  onNotificationAction(listener: (event: NotificationActionEvent) => void): Unsubscribe
  readonly notificationSupportsActions: boolean
  readonly notificationSupportsInlineReply: boolean

  // badge: the debounced count, already decided in shared code
  setBadgeCount(count: number): void

  // links: the URL has passed the allowlist; main checks the scheme again
  openExternal(url: string): void
  onDeepLink(listener: (url: string) => void): Unsubscribe

  // files
  /** Native save dialog. Bytes cross as an ArrayBuffer. */
  saveFile(bytes: ArrayBuffer, suggestedName: string): Promise<"saved" | "cancelled" | "failed">
  /** Only paths this app saved; main keeps the list and refuses others. */
  revealInFolder(path: string): void

  // window
  setTitle(title: string): void
  openWindow(path?: string): void
  setAlwaysOnTop(on: boolean): void
  isAlwaysOnTop(): boolean
  titleBarInsets(): TitleBarInsets | null
  onTitleBarInsets(listener: (insets: TitleBarInsets) => void): Unsubscribe

  // lifecycle: main's powerMonitor knows about sleep directly
  onSystemResume(listener: () => void): Unsubscribe

  // updater
  updateState(): UpdateState
  onUpdateState(listener: (state: UpdateState) => void): Unsubscribe
  applyUpdate(): void

  // desktop-only
  setSpellcheck(on: boolean): void
  spellcheckEnabled(): boolean
  setTrayChats(chats: readonly TrayChat[]): void
  onTraySelect(listener: (data: NotificationData) => void): Unsubscribe
  setLaunchAtLogin(on: boolean): Promise<void>
  launchAtLogin(): boolean
  setGlobalShortcut(accelerator: string | null): Promise<boolean>
  globalShortcut(): string | null
}
