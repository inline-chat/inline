/**
 * The settings pages and the rows on them, as data. Page rows read their
 * titles from here and search indexes the same entries, so the two cannot
 * drift (the Mac app's `SettingsSearchItem` does the same).
 *
 * Page IDs are the `settings` destination's pages (`@inline/view`), so the
 * URL is `/settings/<page>`. Two web pages reuse the nearest Mac page's ID:
 * Keyboard Shortcuts is `hotkeys` and About is `updates`.
 */

import type { SettingsPage } from "@inline/view"

export type SettingsPageId = Extract<
  SettingsPage,
  "account" | "general" | "appearance" | "notifications" | "data" | "hotkeys" | "updates"
>

export type SettingsIcon = "account" | "general" | "appearance" | "notifications" | "data" | "shortcuts" | "about"

export type SettingsPageSpec = {
  readonly id: SettingsPageId
  readonly title: string
  readonly icon: SettingsIcon
  /** Pages in the same group sit together in the list, as in the Mac sidebar. */
  readonly group: number
  /** Shown only with a signed-in account. */
  readonly needsAccount?: boolean
}

/** Mac order (`SettingsCategory.sidebarGroups`), with the pages the web has. */
export const SETTINGS_PAGES: readonly SettingsPageSpec[] = [
  { id: "account", title: "Account", icon: "account", group: 0, needsAccount: true },
  { id: "general", title: "General", icon: "general", group: 1 },
  { id: "appearance", title: "Appearance", icon: "appearance", group: 1 },
  { id: "notifications", title: "Notifications", icon: "notifications", group: 1 },
  { id: "data", title: "Data & Storage", icon: "data", group: 2 },
  { id: "hotkeys", title: "Keyboard Shortcuts", icon: "shortcuts", group: 3 },
  { id: "updates", title: "About", icon: "about", group: 4 },
]

/** The page `/settings` opens, as on the Mac. */
export const DEFAULT_SETTINGS_PAGE: SettingsPageId = "general"

/** Mac pages the web does not have yet, for a link from elsewhere (`/settings/privacy`). */
export const UNAVAILABLE_PAGE_TITLES: Partial<Record<SettingsPage, string>> = {
  sessions: "Active Sessions",
  "audio-video": "Audio and Video",
  bots: "Bots",
  connectors: "Connectors",
  privacy: "Privacy",
  experimental: "Experimental",
  debug: "Debug",
}

export const isSettingsPageId = (page: unknown): page is SettingsPageId =>
  SETTINGS_PAGES.some((spec) => spec.id === page)

export const pageSpec = (id: SettingsPageId): SettingsPageSpec => {
  const spec = SETTINGS_PAGES.find((candidate) => candidate.id === id)
  if (!spec) throw new Error(`Unknown settings page: ${id}`)
  return spec
}

export type SettingsItemSpec = {
  readonly id: string
  readonly page: SettingsPageId
  /** The row's label. */
  readonly title: string
  /** The section header the row sits under. */
  readonly section: string
  /** Words people may type that are not in the title or section. */
  readonly keywords: readonly string[]
}

const item = (
  page: SettingsPageId,
  section: string,
  id: string,
  title: string,
  keywords: readonly string[] = [],
): SettingsItemSpec => ({ id, page, section, title, keywords })

/** Every searchable row, in page order, then row order. Titles and keywords follow `SettingsSearchItem.swift`. */
export const SETTINGS_ITEMS = [
  item("account", "Profile", "profile", "Profile", ["name", "photo", "avatar", "picture"]),
  item("account", "Account", "username", "Username", ["handle", "public name"]),
  item("account", "Account", "email", "Email", ["mail", "address"]),
  item("account", "Session", "thisDevice", "This Device", ["sign out", "log out", "logout", "browser", "device name"]),

  item("general", "Writing", "sendMessages", "Send Messages", ["return", "enter", "command", "cmd", "ctrl", "keyboard"]),
  item("general", "Writing", "checkSpelling", "Check Spelling While Typing", ["spellcheck", "underline", "typo"]),
  item("general", "Messages", "replyThreadsInSidePane", "Open Reply Threads in Side Pane", ["thread", "replies", "split", "pane"]),

  item("appearance", "Appearance", "appearance", "Appearance", ["dark mode", "light mode", "system", "auto"]),
  item("appearance", "Appearance", "theme", "Theme", ["colors", "palette", "accent"]),
  item("appearance", "Sidebar", "sidebarItemSize", "Item Size", ["density", "compact", "row height"]),
  item("appearance", "Message Text", "fonts", "Font", ["font family", "typeface", "typography", "monospace"]),
  item("appearance", "Message Text", "fontSize", "Text Size", ["font size", "text size", "bigger", "smaller", "zoom", "typography"]),
  item("appearance", "Message Text", "lineSpacing", "Line Spacing", ["line height", "leading", "spacing", "typography"]),
  item("appearance", "Badges", "unreadBadgeStyle", "Unread Badge Style", ["count", "dot", "unread", "numbered"]),

  item("notifications", "Notifications", "notificationPermission", "Notifications in This Browser", [
    "permission",
    "allow",
    "alerts",
    "desktop",
    "blocked",
  ]),
  item("notifications", "Sound", "notificationSounds", "Notification Sounds", ["alert", "mute", "silent"]),
  item("notifications", "Badge", "appBadge", "Unread Badge", ["dock", "unread", "count", "icon", "tab title", "favicon"]),

  item("data", "Storage", "storageUsage", "Storage Usage", ["disk", "space", "size", "cache", "usage", "quota"]),
  item("data", "Storage", "persistentStorage", "Persistent Storage", ["eviction", "persist", "keep", "offline"]),
  item("data", "Storage", "clearCachedMedia", "Clear Cached Media", ["clear cache", "delete", "free up space", "remove", "clean", "downloads"]),

  item("hotkeys", "Shortcuts", "shortcuts", "Keyboard Shortcuts", ["hotkeys", "keys", "keyboard", "commands"]),

  item("updates", "Inline", "version", "Version", ["build", "build id", "release"]),
  item("updates", "Updates", "softwareUpdate", "Software Update", ["update", "reload", "new version", "install"]),
  item("updates", "Legal", "legal", "Terms and Privacy", ["terms", "privacy", "policy", "legal"]),
] as const satisfies readonly SettingsItemSpec[]

export type SettingsItemId = (typeof SETTINGS_ITEMS)[number]["id"]

const itemsById = new Map<string, SettingsItemSpec>(SETTINGS_ITEMS.map((spec) => [spec.id, spec]))

export const itemSpec = (id: SettingsItemId): SettingsItemSpec => itemsById.get(id) as SettingsItemSpec

export const findItem = (id: string): SettingsItemSpec | undefined => itemsById.get(id)

/** The pages to list: everything, without Account when no account is signed in. */
export const visiblePages = (options: { readonly hasAccount: boolean }): readonly SettingsPageSpec[] =>
  SETTINGS_PAGES.filter((spec) => !spec.needsAccount || options.hasAccount)

/**
 * What a destination's page resolves to: one of `pages`, the default for
 * none, or `unavailable` with a title for a Mac page the web lacks.
 */
export type ResolvedPage =
  | { readonly kind: "page"; readonly id: SettingsPageId }
  | { readonly kind: "unavailable"; readonly page: SettingsPage; readonly title: string }

export const resolvePage = (page: SettingsPage | undefined, pages: readonly SettingsPageSpec[]): ResolvedPage => {
  if (page === undefined) {
    const first = pages.find((spec) => spec.id === DEFAULT_SETTINGS_PAGE) ?? pages[0]
    return { kind: "page", id: first?.id ?? DEFAULT_SETTINGS_PAGE }
  }
  if (pages.some((spec) => spec.id === page)) return { kind: "page", id: page as SettingsPageId }
  const title = UNAVAILABLE_PAGE_TITLES[page] ?? (page === "account" ? "Account" : "Settings")
  return { kind: "unavailable", page, title }
}
