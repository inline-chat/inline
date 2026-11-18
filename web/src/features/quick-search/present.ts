/**
 * Pure helpers the palette's rows and keyboard handling use: highlight
 * segments, row labels, shortcut keys, dates, item equality and the key map.
 * No DOM and no framework, so all of it is unit-tested in Node.
 */

import type { MatchRange, QuickSearchItem } from "@inline/view/quick-search"
import { commandCategories, formatCombo, isComposingEvent, type CommandCategory, type KeyCombo, type OS, type OpenIntent } from "@inline/view"

// ---------------------------------------------------------------------------
// Highlights

export type TextSegment = { readonly text: string; readonly highlighted: boolean }

const isHigh = (code: number) => code >= 0xd800 && code <= 0xdbff
const isLow = (code: number) => code >= 0xdc00 && code <= 0xdfff

/**
 * Split `text` at the matcher's ranges (UTF-16 offsets) into plain and
 * highlighted runs, for rendering as text nodes. Ranges are clamped to the
 * text, sorted and merged; a boundary inside a surrogate pair is moved
 * outward so no half character is ever produced. Bad input yields the whole
 * text as one plain run.
 */
export const highlightSegments = (text: string, ranges: readonly MatchRange[] | undefined): readonly TextSegment[] => {
  const value = typeof text === "string" ? text : ""
  if (value.length === 0) return []
  const length = value.length
  const clean: [number, number][] = []
  for (const range of ranges ?? []) {
    if (!Array.isArray(range)) continue
    let start = Math.max(0, Math.min(length, Math.floor(Number(range[0]))))
    let end = Math.max(0, Math.min(length, Math.floor(Number(range[1]))))
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) continue
    if (start > 0 && isLow(value.charCodeAt(start)) && isHigh(value.charCodeAt(start - 1))) start -= 1
    if (end < length && isLow(value.charCodeAt(end)) && isHigh(value.charCodeAt(end - 1))) end += 1
    clean.push([start, end])
  }
  if (clean.length === 0) return [{ text: value, highlighted: false }]
  clean.sort((a, b) => a[0] - b[0] || a[1] - b[1])
  const merged: [number, number][] = []
  for (const range of clean) {
    const last = merged[merged.length - 1]
    if (last && range[0] <= last[1]) last[1] = Math.max(last[1], range[1])
    else merged.push([range[0], range[1]])
  }
  const segments: TextSegment[] = []
  let at = 0
  for (const [start, end] of merged) {
    if (start > at) segments.push({ text: value.slice(at, start), highlighted: false })
    segments.push({ text: value.slice(start, end), highlighted: true })
    at = end
  }
  if (at < length) segments.push({ text: value.slice(at), highlighted: false })
  return segments
}

// ---------------------------------------------------------------------------
// Labels

/** The trailing label the Mac row shows for each kind. Commands show their category. */
export const kindLabel = (item: QuickSearchItem): string => {
  switch (item.kind) {
    case "chat":
      return item.peerUserId !== undefined ? "User" : "Thread"
    case "user":
      return item.user?.bot ? "Bot" : "User"
    case "space":
      return "Space"
    case "command":
      return commandCategories[item.category as CommandCategory] ?? "Command"
    case "createThread":
      return "Command"
    case "message":
      return "Message"
  }
}

/** The accessible name of a row: what it is, then what a sighted user reads. */
export const itemLabel = (item: QuickSearchItem, extra?: string): string => {
  const parts: string[] = [item.title]
  if (item.kind === "message") {
    if (item.snippet) parts.push(item.snippet)
  } else if (item.subtitle && item.subtitle !== item.title) {
    parts.push(item.subtitle)
  }
  parts.push(kindLabel(item))
  if (extra) parts.push(extra)
  return parts.join(", ")
}

// ---------------------------------------------------------------------------
// Shortcuts

const macModifiers = new Set(["⌃", "⌥", "⇧", "⌘"])

/**
 * The keys of a combo for the kit's `Kbd`, from the registry's formatted
 * text: `⌘K` becomes `["⌘", "K"]` on Mac, `Ctrl+Shift+K` becomes
 * `["Ctrl", "Shift", "K"]` elsewhere (a `+` key stays one key).
 */
export const shortcutKeys = (combo: KeyCombo, os: OS): readonly string[] => {
  const text = formatCombo(combo, os)
  if (os === "mac") {
    const keys: string[] = []
    let rest = text
    while (rest.length > 1 && macModifiers.has(rest[0] ?? "")) {
      keys.push(rest[0] as string)
      rest = rest.slice(1)
    }
    if (rest) keys.push(rest)
    return keys
  }
  const keys: string[] = []
  let current = ""
  for (let index = 0; index < text.length; index++) {
    const char = text[index] as string
    if (char === "+" && current !== "") {
      keys.push(current)
      current = ""
    } else {
      current += char
    }
  }
  if (current) keys.push(current)
  return keys
}

// ---------------------------------------------------------------------------
// Dates

const DAY_MS = 86_400_000
const dateCache = new Map<string, string>()
const DATE_CACHE_LIMIT = 512
let formatters: { time: Intl.DateTimeFormat; day: Intl.DateTimeFormat; year: Intl.DateTimeFormat } | undefined

const getFormatters = () => {
  formatters ??= {
    time: new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }),
    day: new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }),
    year: new Intl.DateTimeFormat(undefined, { year: "numeric", month: "short", day: "numeric" }),
  }
  return formatters
}

const localDay = (date: Date) => `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`

/**
 * A message hit's time: the clock time today, the day this year, the full
 * date otherwise. Cached per (date, today) so rows do no formatting work on
 * re-render.
 */
export const formatHitDate = (seconds: number, nowMs: number): string => {
  if (!Number.isFinite(seconds) || seconds <= 0) return ""
  const now = new Date(nowMs)
  const key = `${seconds}|${localDay(now)}`
  const cached = dateCache.get(key)
  if (cached !== undefined) return cached
  const date = new Date(seconds * 1000)
  const f = getFormatters()
  let label: string
  if (localDay(date) === localDay(now)) label = f.time.format(date)
  else if (date.getFullYear() === now.getFullYear() && nowMs - date.getTime() < 366 * DAY_MS) label = f.day.format(date)
  else label = f.year.format(date)
  if (dateCache.size >= DATE_CACHE_LIMIT) {
    const oldest = dateCache.keys().next()
    if (!oldest.done) dateCache.delete(oldest.value)
  }
  dateCache.set(key, label)
  return label
}

// ---------------------------------------------------------------------------
// Item equality, for memoized rows

const sameRanges = (a: readonly MatchRange[], b: readonly MatchRange[]): boolean =>
  a === b || (a.length === b.length && a.every((range, index) => range[0] === b[index]?.[0] && range[1] === b[index]?.[1]))

/**
 * Whether two items render the same. The model keeps item identity for
 * results that did not change; local items are rebuilt per query, and this
 * lets a row whose content is the same skip its render anyway.
 */
export const sameItem = (a: QuickSearchItem, b: QuickSearchItem): boolean => {
  if (a === b) return true
  if (a.kind !== b.kind || a.id !== b.id || a.title !== b.title || a.subtitle !== b.subtitle || a.section !== b.section) return false
  if (!sameRanges(a.titleRanges, b.titleRanges)) return false
  const left = a as Record<string, unknown>
  const right = b as Record<string, unknown>
  const keys = new Set([...Object.keys(left), ...Object.keys(right)])
  for (const key of keys) {
    if (key === "titleRanges") continue
    const x = left[key]
    const y = right[key]
    if (x === y) continue
    if (key === "snippetRanges" && Array.isArray(x) && Array.isArray(y) && sameRanges(x as MatchRange[], y as MatchRange[])) continue
    return false
  }
  return true
}

// ---------------------------------------------------------------------------
// Keys

export type PaletteKeyAction =
  | { readonly kind: "next" | "previous" | "first" | "last" | "nextSection" | "previousSection" }
  | { readonly kind: "activate"; readonly intent: OpenIntent }
  | { readonly kind: "close" }

export type PaletteKeyInput = {
  readonly key: string
  readonly metaKey?: boolean
  readonly ctrlKey?: boolean
  readonly altKey?: boolean
  readonly shiftKey?: boolean
  readonly isComposing?: boolean
  readonly keyCode?: number
}

/** Cmd on Mac, Ctrl elsewhere. */
export const hasMod = (event: Pick<PaletteKeyInput, "metaKey" | "ctrlKey">, os: OS): boolean =>
  os === "mac" ? !!event.metaKey : !!event.ctrlKey

/**
 * What a key in the field does, or undefined to let the field have it.
 * Nothing fires while an input method is composing.
 *
 * | Key | Action |
 * | --- | --- |
 * | Down / Up (Ctrl+N / Ctrl+P on Mac) | next / previous |
 * | Mod+Down / Mod+Up | last / first |
 * | Home / End (when the field is empty) | first / last |
 * | Tab / Shift+Tab | next / previous section |
 * | Enter | activate here |
 * | Mod+Enter | activate in the other pane |
 * | Mod+K | close (the shortcut that opened it) |
 *
 * Home and End move the caret while there is text, as in any text field;
 * Escape is the dialog's (the dismiss stack closes the topmost layer).
 */
export const paletteKeyAction = (event: PaletteKeyInput, os: OS, fieldEmpty: boolean): PaletteKeyAction | undefined => {
  if (isComposingEvent({ key: event.key, ctrlKey: !!event.ctrlKey, metaKey: !!event.metaKey, altKey: !!event.altKey, shiftKey: !!event.shiftKey, ...(event.isComposing !== undefined ? { isComposing: event.isComposing } : {}), ...(event.keyCode !== undefined ? { keyCode: event.keyCode } : {}) })) {
    return undefined
  }
  const mod = hasMod(event, os)
  const plain = !event.metaKey && !event.ctrlKey && !event.altKey
  switch (event.key) {
    case "ArrowDown":
      if (mod && !event.altKey) return { kind: "last" }
      if (plain) return { kind: "next" }
      return undefined
    case "ArrowUp":
      if (mod && !event.altKey) return { kind: "first" }
      if (plain) return { kind: "previous" }
      return undefined
    case "Home":
      return plain && fieldEmpty ? { kind: "first" } : undefined
    case "End":
      return plain && fieldEmpty ? { kind: "last" } : undefined
    case "Tab":
      if (event.metaKey || event.ctrlKey || event.altKey) return undefined
      return { kind: event.shiftKey ? "previousSection" : "nextSection" }
    case "Enter":
      if (event.altKey || event.shiftKey) return undefined
      if (mod) return { kind: "activate", intent: "otherPane" }
      if (plain) return { kind: "activate", intent: "here" }
      return undefined
  }
  // Emacs-style list keys, as in macOS text fields and menus.
  if (os === "mac" && event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey) {
    const key = event.key.toLowerCase()
    if (key === "n") return { kind: "next" }
    if (key === "p") return { kind: "previous" }
  }
  if (mod && !event.altKey && !event.shiftKey && event.key.toLowerCase() === "k") return { kind: "close" }
  return undefined
}

/** How a click opens an item: Mod-click in the other pane, a middle click in a new tab. */
export const pointerIntent = (event: { readonly button: number; readonly metaKey?: boolean; readonly ctrlKey?: boolean }, os: OS): OpenIntent | undefined => {
  if (event.button === 1) return "newTab"
  if (event.button !== 0) return undefined
  return hasMod(event, os) ? "otherPane" : "here"
}

// ---------------------------------------------------------------------------
// Scrolling

/**
 * How far to scroll a list so `target` (top and bottom, relative to the
 * viewport) is fully inside `view`, keeping `padding` from its edges. Zero
 * when it already is. A target taller than the view aligns its top.
 */
export const revealDelta = (
  view: { readonly top: number; readonly bottom: number },
  target: { readonly top: number; readonly bottom: number },
  padding = 0,
): number => {
  const top = view.top + padding
  const bottom = view.bottom - padding
  if (target.top < top) return target.top - top
  if (target.bottom > bottom) return Math.min(target.bottom - bottom, target.top - top)
  return 0
}

/** Whether a pointer event is real movement, not a synthetic one after a scroll or re-render. */
export const pointerMoved = (
  last: { readonly x: number; readonly y: number } | undefined,
  next: { readonly x: number; readonly y: number },
): boolean => !last || last.x !== next.x || last.y !== next.y

// ---------------------------------------------------------------------------
// Message hit columns

/** The message title column's bounds (the palette's `messageTitle` style says the same in CSS). */
export const messageTitleColumn = { minEm: 7, share: 0.4, maxEm: 16 } as const

/**
 * The widest a message hit's chat title may be, in pixels, for a text column
 * of `columnPx` and a font size of `emPx`: 40% of the column, at least 7em
 * (or half the column when that is narrower), at most 16em. The title is
 * never narrower than its own text up to this; the snippet takes the rest.
 * CSS `clamp(min(7em, 50%), 40%, 16em)`: when the minimum exceeds the
 * maximum, the minimum wins.
 */
export const messageTitleMaxWidth = (columnPx: number, emPx: number): number => {
  const column = Math.max(0, columnPx)
  const min = Math.min(messageTitleColumn.minEm * emPx, column / 2)
  const max = messageTitleColumn.maxEm * emPx
  return Math.max(min, Math.min(column * messageTitleColumn.share, max))
}
