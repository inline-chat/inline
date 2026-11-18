/**
 * Pure helpers for the find bar: the key map, preview snippets with their
 * highlighted runs, the list's window over fixed-height rows, and
 * shortcut hints. No DOM, no framework.
 */

import { formatCombo, parseCombo, shortcutTextsFor, type KeyCombo, type KeyEventLike, type Platform, type ShortcutSpec } from "@inline/view"
import type { SearchRange } from "./find-source"

// ---------------------------------------------------------------------------
// Keys in the field

/**
 * - `submit`: Enter. Over the list, show the chosen match; over the chat, the next match.
 * - `previous`: Shift+Enter, or Down over the chat (the next newer match).
 * - `next`: Up over the chat (the next older match, like Telegram).
 * - `moveNewer` / `moveOlder`: Up / Down over the list (newest on top).
 * - `close`: Escape.
 */
export type FindKeyAction = "submit" | "next" | "previous" | "moveNewer" | "moveOlder" | "close"

/** What a key in the find field does, or undefined to leave it to the field and the app. */
export const findKeyAction = (event: KeyEventLike, state: { readonly showsResults: boolean }): FindKeyAction | undefined => {
  if (event.isComposing === true || event.keyCode === 229) return undefined
  const modified = event.ctrlKey || event.metaKey || event.altKey
  switch (event.key) {
    case "Escape":
    case "Esc":
      return modified || event.shiftKey ? undefined : "close"
    case "Enter":
      if (modified) return undefined
      return event.shiftKey ? "previous" : "submit"
    case "ArrowUp":
    case "Up":
      if (modified || event.shiftKey) return undefined
      return state.showsResults ? "moveNewer" : "next"
    case "ArrowDown":
    case "Down":
      if (modified || event.shiftKey) return undefined
      return state.showsResults ? "moveOlder" : "previous"
    default:
      return undefined
  }
}

// ---------------------------------------------------------------------------
// Snippets

export type TextRun = { readonly text: string; readonly highlighted: boolean }

const isHigh = (code: number) => code >= 0xd800 && code <= 0xdbff
const isLow = (code: number) => code >= 0xdc00 && code <= 0xdfff
const isSpace = (char: string) => /\s/.test(char)

/** Sorted, merged, clamped ranges that never split a surrogate pair. */
export const normalizeRanges = (text: string, ranges: readonly SearchRange[] | undefined): [number, number][] => {
  const length = text.length
  const clean: [number, number][] = []
  for (const range of ranges ?? []) {
    if (!Array.isArray(range)) continue
    let start = Math.max(0, Math.min(length, Math.floor(Number(range[0]))))
    let end = Math.max(0, Math.min(length, Math.floor(Number(range[1]))))
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) continue
    if (start > 0 && isLow(text.charCodeAt(start)) && isHigh(text.charCodeAt(start - 1))) start -= 1
    if (end < length && isLow(text.charCodeAt(end)) && isHigh(text.charCodeAt(end - 1))) end += 1
    clean.push([start, end])
  }
  clean.sort((a, b) => a[0] - b[0] || a[1] - b[1])
  const merged: [number, number][] = []
  for (const range of clean) {
    const last = merged[merged.length - 1]
    if (last && range[0] <= last[1]) last[1] = Math.max(last[1], range[1])
    else merged.push([range[0], range[1]])
  }
  return merged
}

/**
 * One line of text around the first match, as runs to render as text nodes
 * (matched runs in `<mark>`). Whitespace runs collapse to one space,
 * ellipses mark cuts. The Mac's `InChatSearchText.snippet`: from 24
 * characters before the match to 96 after it.
 */
export const snippetRuns = (
  text: string,
  ranges: readonly SearchRange[] | undefined,
  options: { readonly before?: number; readonly after?: number } = {},
): readonly TextRun[] => {
  const value = typeof text === "string" ? text : ""
  if (value.length === 0) return []
  const before = options.before ?? 24
  const after = options.after ?? 96
  const merged = normalizeRanges(value, ranges)
  const first = merged[0]
  let start = first ? Math.max(0, first[0] - before) : 0
  let end = first ? Math.min(value.length, first[1] + after) : Math.min(value.length, before + after)
  if (start > 0 && isLow(value.charCodeAt(start)) && isHigh(value.charCodeAt(start - 1))) start -= 1
  if (end < value.length && isLow(value.charCodeAt(end)) && isHigh(value.charCodeAt(end - 1))) end += 1

  const runs: { text: string; highlighted: boolean }[] = []
  let rangeIndex = 0
  let previousSpace = true // drops leading whitespace
  for (let index = start; index < end; index++) {
    while (rangeIndex < merged.length && (merged[rangeIndex] as [number, number])[1] <= index) rangeIndex++
    const range = merged[rangeIndex]
    const highlighted = range !== undefined && range[0] <= index && index < range[1]
    let char = value[index] as string
    if (isSpace(char)) {
      if (previousSpace) continue
      char = " "
      previousSpace = true
    } else {
      previousSpace = false
    }
    const last = runs[runs.length - 1]
    if (last && last.highlighted === highlighted) last.text += char
    else runs.push({ text: char, highlighted })
  }
  // Trailing whitespace.
  const tail = runs[runs.length - 1]
  if (tail && tail.text.endsWith(" ")) {
    tail.text = tail.text.slice(0, -1)
    if (tail.text.length === 0) runs.pop()
  }
  if (start > 0) {
    const head = runs[0]
    if (head && !head.highlighted) head.text = `…${head.text}`
    else runs.unshift({ text: "…", highlighted: false })
  }
  if (end < value.length) {
    const last = runs[runs.length - 1]
    if (last && !last.highlighted) last.text = `${last.text}…`
    else runs.push({ text: "…", highlighted: false })
  }
  return runs
}

// ---------------------------------------------------------------------------
// The list: fixed-height rows, a bounded window of them in the DOM

/** Mac `InChatSearchResultsPanel`: 54 pt rows, at most seven visible, 6 pt inset. */
export const findListMetrics = {
  rowHeight: 54,
  maxVisibleRows: 7,
  inset: 6,
  footerHeight: 30,
  /** Rows rendered beyond each edge of the viewport. */
  overscan: 6,
} as const

export type ListWindow = {
  /** First rendered index. */
  readonly start: number
  /** One past the last rendered index. */
  readonly end: number
  /** Space above the first rendered row. */
  readonly before: number
  /** Space below the last rendered row. */
  readonly after: number
}

/** Which rows to render for a scroll position (the content's top inset excluded). */
export const listWindow = (input: {
  readonly scrollTop: number
  readonly viewportHeight: number
  readonly count: number
  readonly rowHeight?: number
  readonly overscan?: number
}): ListWindow => {
  const rowHeight = input.rowHeight ?? findListMetrics.rowHeight
  const overscan = input.overscan ?? findListMetrics.overscan
  const count = Math.max(0, Math.floor(input.count))
  if (count === 0) return { start: 0, end: 0, before: 0, after: 0 }
  const top = Math.max(0, input.scrollTop - findListMetrics.inset)
  const first = Math.floor(top / rowHeight)
  const visible = Math.ceil(Math.max(input.viewportHeight, rowHeight) / rowHeight) + 1
  const start = Math.max(0, Math.min(count - 1, first - overscan))
  const end = Math.min(count, first + visible + overscan)
  return { start, end, before: start * rowHeight, after: (count - end) * rowHeight }
}

/** The scroll position that shows row `index` whole (keeping the inset's gap), or undefined if it already shows. */
export const revealRow = (input: {
  readonly index: number
  readonly scrollTop: number
  readonly viewportHeight: number
  readonly rowHeight?: number
}): number | undefined => {
  const rowHeight = input.rowHeight ?? findListMetrics.rowHeight
  const inset = findListMetrics.inset
  const top = inset + input.index * rowHeight
  const bottom = top + rowHeight
  if (top - inset < input.scrollTop) return Math.max(0, top - inset)
  if (bottom + inset > input.scrollTop + input.viewportHeight) return bottom + inset - input.viewportHeight
  return undefined
}

/** The list's height: up to seven rows, the footer, the inset at both ends. */
export const listHeight = (rows: number, footer: boolean): number =>
  Math.min(rows, findListMetrics.maxVisibleRows) * findListMetrics.rowHeight +
  (footer ? findListMetrics.footerHeight : 0) +
  findListMetrics.inset * 2

// ---------------------------------------------------------------------------
// Shortcut hints

const firstCombo = (spec: ShortcutSpec, platform: Platform): KeyCombo | undefined => {
  const text = shortcutTextsFor(spec, platform)[0]
  return text === undefined ? undefined : parseCombo(text, platform.os)
}

/** The first shortcut of a spec on a platform, formatted ("⌘G", "Ctrl+G"), or undefined. */
export const shortcutHint = (spec: ShortcutSpec, platform: Platform): string | undefined => {
  const combo = firstCombo(spec, platform)
  return combo ? formatCombo(combo, platform.os) : undefined
}

/** `aria-keyshortcuts` for a spec's first shortcut ("Meta+G", "Control+Shift+G"). */
export const ariaShortcut = (spec: ShortcutSpec, platform: Platform): string | undefined => {
  const combo = firstCombo(spec, platform)
  if (!combo) return undefined
  const parts: string[] = []
  if (combo.ctrl) parts.push("Control")
  if (combo.meta) parts.push("Meta")
  if (combo.alt) parts.push("Alt")
  if (combo.shift) parts.push("Shift")
  parts.push(combo.key.length === 1 ? combo.key.toUpperCase() : combo.key)
  return parts.join("+")
}

/** Seconds since the epoch as the Mac shows a match's date: time today, "Mar 4" this year, else a numeric date. */
export const formatFindDate = (seconds: number, nowMs: number): string => {
  if (!Number.isFinite(seconds) || seconds <= 0) return ""
  const date = new Date(seconds * 1000)
  const now = new Date(nowMs)
  const sameDay = date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth() && date.getDate() === now.getDate()
  if (sameDay) return timeFormat().format(date)
  if (date.getFullYear() === now.getFullYear()) return dayFormat().format(date)
  return numericFormat().format(date)
}

let formats: { time: Intl.DateTimeFormat; day: Intl.DateTimeFormat; numeric: Intl.DateTimeFormat } | undefined
const getFormats = () =>
  (formats ??= {
    time: new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }),
    day: new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }),
    numeric: new Intl.DateTimeFormat(undefined, { year: "numeric", month: "numeric", day: "numeric" }),
  })
const timeFormat = () => getFormats().time
const dayFormat = () => getFormats().day
const numericFormat = () => getFormats().numeric
