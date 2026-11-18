/**
 * Words and numbers the settings pages show, as pure functions: byte sizes,
 * key caps, and the plain-language states of notifications, storage and
 * updates. Strings stay out of the views so a translation layer can wrap
 * them later.
 */

import type { OperatingSystem, PlatformKind, UpdateState } from "@inline/platform"
import type { OS, ShortcutReference, ShortcutReferenceCategory } from "@inline/view"
import type { PermissionState } from "../notifications"
import type { SendKey } from "./preferences"
import { foldText, searchWords } from "./search"

// ---------------------------------------------------------------------------
// Bytes

const BYTE_UNITS = ["byte", "kilobyte", "megabyte", "gigabyte", "terabyte"] as const

/**
 * A size in decimal units, as Apple's storage views count them (1 KB is 1000
 * bytes), localized with `Intl.NumberFormat`: "512 bytes", "1.5 MB", "12 GB".
 */
export const formatBytes = (bytes: number, locale?: string): string => {
  const value = Number.isFinite(bytes) && bytes > 0 ? bytes : 0
  let unit = 0
  let scaled = value
  while (scaled >= 1000 && unit < BYTE_UNITS.length - 1) {
    scaled /= 1000
    unit += 1
  }
  return new Intl.NumberFormat(locale, {
    style: "unit",
    unit: BYTE_UNITS[unit],
    unitDisplay: unit === 0 ? "long" : "short",
    maximumFractionDigits: unit === 0 || scaled >= 100 ? 0 : 1,
  }).format(scaled)
}

/** "1.2 MB of 2 GB available to Inline", or just the usage when the quota is unknown. */
export const formatUsage = (estimate: { readonly usage: number; readonly quota: number }, locale?: string): string => {
  const used = formatBytes(estimate.usage, locale)
  return estimate.quota > 0 ? `${used} of ${formatBytes(estimate.quota, locale)} this browser allows` : used
}

// ---------------------------------------------------------------------------
// Keys

const MAC_MODIFIERS: Record<string, string> = { "⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command" }

/**
 * Key caps for a display string from the shortcut reference: `⌘⇧E` gives
 * `["⌘", "⇧", "E"]` on a Mac; `Ctrl+Shift+E` gives `["Ctrl", "Shift", "E"]`,
 * and `Ctrl++` gives `["Ctrl", "+"]`.
 */
export const keyCaps = (display: string, os: OS): readonly string[] => {
  if (os === "mac") {
    const caps: string[] = []
    let index = 0
    const chars = Array.from(display)
    while (index < chars.length && MAC_MODIFIERS[chars[index] ?? ""] !== undefined) {
      caps.push(chars[index] ?? "")
      index += 1
    }
    const key = chars.slice(index).join("")
    if (key) caps.push(key)
    return caps
  }
  if (display.endsWith("++")) return [...display.slice(0, -2).split("+").filter(Boolean), "+"]
  if (display === "+") return ["+"]
  return display.split("+").filter(Boolean)
}

/** What assistive technology reads for a combo: "Command Shift E", "Ctrl Shift E". */
export const spokenCombo = (display: string, os: OS): string =>
  keyCaps(display, os)
    .map((cap) => (os === "mac" ? (MAC_MODIFIERS[cap] ?? cap) : cap))
    .join(" ")

/** The shortcut reference, keeping commands that have a key here and match the filter (title, category or key). */
export const filterShortcuts = (reference: ShortcutReference, query: string): readonly ShortcutReferenceCategory[] => {
  const tokens = searchWords(query)
  const raw = foldText(query.trim())
  return reference.categories
    .map((category) => ({
      ...category,
      commands: category.commands.filter((command) => {
        if (command.keys.length === 0) return false
        if (tokens.length === 0 && raw === "") return true
        const words = [...searchWords(command.title), ...searchWords(category.title)]
        const wordsMatch = tokens.length > 0 && tokens.every((token) => words.some((word) => word.startsWith(token)))
        const keyMatch = raw !== "" && command.keys.some((key) => foldText(key.display).includes(raw))
        return wordsMatch || keyMatch
      }),
    }))
    .filter((category) => category.commands.length > 0)
}

// ---------------------------------------------------------------------------
// General

const isApple = (os: OperatingSystem): boolean => os === "mac" || os === "ios"

/** The send key choices in the platform's words, as the Mac picker shows them. */
export const sendKeyOptions = (os: OperatingSystem): readonly { readonly value: SendKey; readonly label: string }[] =>
  isApple(os)
    ? [
        { value: "enter", label: "Return" },
        { value: "modEnter", label: "⌘ Return" },
      ]
    : [
        { value: "enter", label: "Enter" },
        { value: "modEnter", label: "Ctrl+Enter" },
      ]

export const sendKeyDescription = (sendKey: SendKey, os: OperatingSystem): string => {
  const enter = isApple(os) ? "Return" : "Enter"
  const mod = isApple(os) ? "⌘ Return" : "Ctrl+Enter"
  return sendKey === "enter"
    ? `${enter} sends. Shift+${enter} starts a new line.`
    : `${mod} sends. ${enter} starts a new line.`
}

// ---------------------------------------------------------------------------
// Account

/** What the confirmation says. Plain words: the local copy goes, the account stays. */
export const signOutWarning = (pendingCount: number): string => {
  const base =
    "You will be signed out of Inline in this browser. Messages, drafts and media stored on this device are erased from it. Your account and chats stay as they are."
  if (pendingCount <= 0) return base
  const messages = pendingCount === 1 ? "1 message has" : `${pendingCount} messages have`
  return `${base} ${messages} not been sent yet and will be lost.`
}

// ---------------------------------------------------------------------------
// Notifications

export type PermissionCopy = {
  /** One line: the state. */
  readonly status: string
  /** What it means or what to do. */
  readonly detail: string
  /** Show "Turn On Notifications". */
  readonly canAsk: boolean
}

export const permissionCopy = (state: PermissionState, kind: PlatformKind): PermissionCopy => {
  switch (state) {
    case "granted":
      return {
        status: "On",
        detail:
          kind === "electron"
            ? "Inline shows a notification for new messages."
            : "Inline shows a notification for new messages while it is open in a tab.",
        canAsk: false,
      }
    case "default":
      return {
        status: "Off",
        detail: "Turn notifications on to hear about new messages while Inline is open in a tab.",
        canAsk: true,
      }
    case "denied":
      return {
        status: "Blocked",
        detail:
          kind === "electron"
            ? "Notifications for Inline are turned off in your system settings. Turn them on there."
            : "This browser blocks notifications from Inline. To allow them, open the site settings for this page (the icon at the start of the address bar), allow notifications, then reload.",
        canAsk: false,
      }
    case "unavailable":
      return { status: "Not available", detail: "This browser cannot show notifications.", canAsk: false }
  }
}

// ---------------------------------------------------------------------------
// Storage

export const persistenceCopy = (persisted: boolean | null): { readonly status: string; readonly detail: string } => {
  if (persisted === true) {
    return {
      status: "Persistent",
      detail: "The browser keeps Inline's data on this device until you sign out or clear the site's data.",
    }
  }
  if (persisted === false) {
    return {
      status: "Not persistent",
      detail: "The browser may clear Inline's data on this device when space runs low; messages not yet sent could be lost.",
    }
  }
  return { status: "Unknown", detail: "This browser does not say whether it keeps Inline's data." }
}

// ---------------------------------------------------------------------------
// Updates

export const updateCopy = (state: UpdateState): { readonly status: string; readonly canApply: boolean } => {
  switch (state.status) {
    case "none":
      return { status: "No update is waiting.", canApply: false }
    case "available":
      return { status: state.version ? `Version ${state.version} is downloading.` : "An update is downloading.", canApply: false }
    case "ready":
      return {
        status: state.version ? `Version ${state.version} is ready. Reload to use it.` : "An update is ready. Reload to use it.",
        canApply: true,
      }
  }
}
