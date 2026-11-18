/**
 * The browser objects the web platform uses, as narrow structural types. The
 * real `window`, `document` and `navigator` satisfy them; tests pass
 * happy-dom objects or small fakes. Nothing here reads a global; only
 * `webEnvFromGlobals` does, and only when called.
 */

import type { Clock } from "../clock"
import { systemClock } from "../clock"
import type { NotificationPermissionState, StorageEstimate } from "../platform"
import type { FaviconRenderer } from "./favicon"
import { canvasFaviconRenderer } from "./favicon"

/* oxlint-disable typescript/no-explicit-any -- DOM event listener parameters are bivariant by design */
export interface EventTargetLike {
  addEventListener(type: string, listener: (event: any) => void): void
  removeEventListener(type: string, listener: (event: any) => void): void
}
/* oxlint-enable typescript/no-explicit-any */

export interface ElementLike {
  setAttribute(name: string, value: string): void
  getAttribute(name: string): string | null
  remove(): void
}

export interface AnchorLike extends ElementLike {
  href: string
  download: string
  rel: string
  click(): void
}

export interface LinkElementLike extends ElementLike {
  href: string
  rel: string
}

export interface WebDocumentLike extends EventTargetLike {
  title: string
  readonly visibilityState: string
  hasFocus(): boolean
  readonly head: { appendChild(node: unknown): unknown } | null
  readonly body: { appendChild(node: unknown): unknown } | null
  querySelector(selectors: string): unknown
  createElement(tagName: string): unknown
}

export interface WebWindowLike extends EventTargetLike {
  open(url: string, target: string, features: string): unknown
  focus(): void
  readonly location: { readonly href: string }
  showSaveFilePicker?: (options: {
    suggestedName?: string
  }) => Promise<{ createWritable(): Promise<{ write(data: Blob): Promise<void>; close(): Promise<void> }> }>
}

export interface PermissionStatusLike extends EventTargetLike {
  readonly state: string
}

export interface WebNavigatorLike {
  readonly userAgent: string
  readonly platform?: string
  readonly maxTouchPoints?: number
  readonly userAgentData?: { readonly platform?: string }
  readonly onLine: boolean
  readonly storage?: {
    persist?(): Promise<boolean>
    persisted?(): Promise<boolean>
    estimate?(): Promise<{ usage?: number; quota?: number }>
  }
  readonly permissions?: { query(descriptor: { name: string }): Promise<PermissionStatusLike> }
  setAppBadge?(count?: number): Promise<void>
  clearAppBadge?(): Promise<void>
}

export interface PageNotificationLike {
  onclick: ((event: unknown) => void) | null
  onclose: ((event: unknown) => void) | null
  close(): void
}

export interface PageNotificationOptions {
  body?: string
  tag?: string
  icon?: string
  silent?: boolean
  requireInteraction?: boolean
}

export interface NotificationApiLike {
  readonly permission: string
  requestPermission(): Promise<string>
  new (title: string, options?: PageNotificationOptions): PageNotificationLike
}

export interface UrlApiLike {
  createObjectURL(blob: Blob): string
  revokeObjectURL(url: string): void
}

export interface WebEnv {
  readonly window: WebWindowLike
  readonly document: WebDocumentLike
  readonly navigator: WebNavigatorLike
  /** `window.Notification`; absent where page notifications do not exist. */
  readonly Notification?: NotificationApiLike
  readonly URL?: UrlApiLike
  /** Wall-clock time and timers. */
  readonly clock: Clock
  /** Draws the favicon badge; null skips the favicon (no canvas). */
  readonly favicon: FaviconRenderer | null
}

export const toPermissionState = (value: string | undefined): NotificationPermissionState =>
  value === "granted" || value === "denied" ? value : "default"

export const toEstimate = (value: { usage?: number; quota?: number }): StorageEstimate => ({
  usage: value.usage ?? 0,
  quota: value.quota ?? 0,
})

/** The real browser environment. Throws outside a window. */
export const webEnvFromGlobals = (): WebEnv => {
  const g = globalThis as unknown as {
    window?: WebWindowLike
    document?: WebDocumentLike
    navigator?: WebNavigatorLike
    Notification?: NotificationApiLike
    URL?: UrlApiLike
  }
  if (!g.window || !g.document || !g.navigator) {
    throw new Error("createWebPlatform needs a window; pass an environment outside one")
  }
  return {
    window: g.window,
    document: g.document,
    navigator: g.navigator,
    ...(g.Notification ? { Notification: g.Notification } : {}),
    ...(g.URL ? { URL: g.URL } : {}),
    clock: systemClock(),
    favicon: canvasFaviconRenderer(g.document),
  }
}
