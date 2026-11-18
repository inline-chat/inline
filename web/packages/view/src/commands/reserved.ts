/**
 * Shortcuts the app must not bind, because the OS or the browser owns them:
 * either a page cannot intercept them, or taking them would break something
 * the user relies on (tabs, windows, history, zoom, reload, developer tools).
 *
 * Shortcuts a page may deliberately take over, as Slack, Linear and Google
 * Docs do, are not listed: Mod+K, Mod+F, Mod+S, Mod+B, Mod+I, Mod+U.
 *
 * The browser list applies to a browser tab. Inside the desktop app only the
 * OS list applies, because Electron owns its own tabs and windows.
 */

import type { OS, Platform } from "./platform"
import { comboId, parseCombo } from "./shortcut"

const digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

/** Owned by the operating system on every surface. */
export const osReservedShortcuts: Record<OS, readonly string[]> = {
  mac: [
    "Mod+Tab",
    "Mod+Shift+Tab",
    "Mod+`",
    "Mod+Space",
    "Mod+Alt+Space",
    "Ctrl+Space",
    "Ctrl+Mod+Space",
    "Mod+H",
    "Mod+Alt+H",
    "Mod+M",
    "Mod+Q",
    "Ctrl+Mod+Q",
    "Ctrl+Mod+F",
    "Mod+Alt+Escape",
    "Mod+Alt+D",
    "Mod+Shift+3",
    "Mod+Shift+4",
    "Mod+Shift+5",
    "Mod+Shift+6",
    "Ctrl+ArrowUp",
    "Ctrl+ArrowDown",
    "Ctrl+ArrowLeft",
    "Ctrl+ArrowRight",
  ],
  windows: [
    "Alt+Tab",
    "Alt+Shift+Tab",
    "Alt+F4",
    "Alt+Space",
    "Alt+Escape",
    "Ctrl+Escape",
    "Ctrl+Shift+Escape",
    "Ctrl+Alt+Delete",
  ],
  linux: [
    "Alt+Tab",
    "Alt+Shift+Tab",
    "Alt+F4",
    "Alt+Space",
    "Ctrl+Alt+Delete",
    "Ctrl+Alt+T",
    "Ctrl+Alt+ArrowLeft",
    "Ctrl+Alt+ArrowRight",
    "Ctrl+Alt+ArrowUp",
    "Ctrl+Alt+ArrowDown",
    "Ctrl+Shift+U",
    "Ctrl+Space",
  ],
}

const commonBrowser = (os: OS): string[] => [
  // Tabs and windows.
  "Mod+T",
  "Mod+N",
  "Mod+W",
  "Mod+Shift+T",
  "Mod+Shift+N",
  "Mod+Shift+W",
  "Ctrl+Tab",
  "Ctrl+Shift+Tab",
  "Ctrl+PageUp",
  "Ctrl+PageDown",
  ...digits.map((d) => `Mod+${d}`),
  // Address bar, reload, history, downloads, source.
  "Mod+L",
  "Mod+R",
  "Mod+Shift+R",
  "F5",
  "Mod+Shift+Delete",
  "Mod+Shift+B",
  "Mod+Shift+O",
  "Mod+Shift+A",
  // Zoom.
  "Mod+=",
  "Mod+-",
  "Mod+0",
  // Developer tools.
  "F12",
  ...(os === "mac"
    ? ["Mod+Alt+I", "Mod+Alt+J", "Mod+Alt+C", "Mod+Alt+K", "Mod+Alt+E", "Mod+Alt+M", "Mod+Alt+U"]
    : ["Ctrl+Shift+I", "Ctrl+Shift+J", "Ctrl+Shift+C", "Ctrl+Shift+K", "Ctrl+Shift+E", "Ctrl+Shift+M", "Ctrl+U"]),
]

/** Owned by the browser in a browser tab, in addition to the OS list. */
export const browserReservedShortcuts: Record<OS, readonly string[]> = {
  mac: [
    ...commonBrowser("mac"),
    // History, tab switching and app settings in Safari and Chrome on Mac.
    "Mod+[",
    "Mod+]",
    "Mod+ArrowLeft",
    "Mod+ArrowRight",
    "Mod+Shift+[",
    "Mod+Shift+]",
    "Mod+Alt+ArrowLeft",
    "Mod+Alt+ArrowRight",
    "Mod+Alt+W",
    "Mod+,",
    "Mod+Y",
    "Mod+Shift+J",
    "Mod+Alt+B",
    "Mod+Alt+L",
    "Mod+Shift+L",
    "Mod+Shift+\\",
    "Mod+Shift+F",
  ],
  windows: [
    ...commonBrowser("windows"),
    "Ctrl+F4",
    "Ctrl+Shift+Q",
    "Ctrl+Shift+PageUp",
    "Ctrl+Shift+PageDown",
    "Alt+ArrowLeft",
    "Alt+ArrowRight",
    "Alt+Home",
    "Alt+D",
    "Alt+F",
    "Alt+E",
    "F6",
    "F7",
    "F11",
    "Ctrl+F5",
    "Ctrl+H",
    "Ctrl+J",
  ],
  linux: [
    ...commonBrowser("linux"),
    "Ctrl+F4",
    "Ctrl+Shift+Q",
    "Ctrl+Shift+PageUp",
    "Ctrl+Shift+PageDown",
    "Alt+ArrowLeft",
    "Alt+ArrowRight",
    "Alt+Home",
    "Alt+D",
    "Alt+F",
    "Alt+E",
    "F6",
    "F7",
    "F11",
    "Ctrl+F5",
    "Ctrl+H",
    "Ctrl+J",
    "Ctrl+Shift+Y",
    ...digits.map((d) => `Alt+${d}`),
  ],
}

/** The reserved combos on a platform, as `comboId`s. */
export const reservedComboIds = (platform: Platform): ReadonlySet<string> => {
  const texts = [
    ...osReservedShortcuts[platform.os],
    ...(platform.surface === "browser" ? browserReservedShortcuts[platform.os] : []),
  ]
  return new Set(texts.map((text) => comboId(parseCombo(text, platform.os))))
}

/** Whether a combo text is reserved on a platform. */
export const isReservedShortcut = (text: string, platform: Platform): boolean =>
  reservedComboIds(platform).has(comboId(parseCombo(text, platform.os)))
