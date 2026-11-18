/**
 * Find in chat: which rows show a persistent highlight, and where. The find
 * controller (later work) decides the matches; this model hands each row a
 * per-row signal of its ranges, so only rows whose ranges change re-render
 * when the active match moves. Framework-free.
 *
 * Ranges are UTF-16 `[start, end)` offsets into `MessageRow.text`, the same
 * units as entities.
 */

import type { MessageRowId } from "@inline/core-protocol"
import { computed, type ReadSignal, signal } from "@inline/reactive"

export type FindRange = readonly [start: number, end: number]
export type FindRanges = readonly FindRange[]

/** Equal when both are absent or hold the same ranges in the same order. */
export const sameRanges = (a: FindRanges | undefined, b: FindRanges | undefined): boolean => {
  if (a === b) return true
  if (!a || !b || a.length !== b.length) return false
  return a.every((range, index) => range[0] === b[index]?.[0] && range[1] === b[index]?.[1])
}

/**
 * Ranges ready for a row: whole numbers, clipped to the text, empty ones
 * dropped, sorted, overlapping or touching ones merged. Undefined when none
 * remain, so a row without a match reads nothing.
 */
export const normalizeRanges = (ranges: Iterable<FindRange>, textLength: number): FindRanges | undefined => {
  const clipped: [number, number][] = []
  for (const [rawStart, rawEnd] of ranges) {
    if (!Number.isFinite(rawStart) || !Number.isFinite(rawEnd)) continue
    const start = Math.max(0, Math.floor(rawStart))
    const end = Math.min(textLength, Math.ceil(rawEnd))
    if (end > start) clipped.push([start, end])
  }
  if (clipped.length === 0) return undefined
  clipped.sort((a, b) => a[0] - b[0] || a[1] - b[1])
  const merged: [number, number][] = []
  for (const range of clipped) {
    const last = merged.at(-1)
    if (last && range[0] <= last[1]) last[1] = Math.max(last[1], range[1])
    else merged.push(range)
  }
  return merged
}

/** Every case-insensitive occurrence of `query` in `text`, for simple callers and the lab. */
export const findOccurrences = (text: string, query: string): FindRanges | undefined => {
  if (query.length === 0) return undefined
  const haystack = text.toLocaleLowerCase()
  const needle = query.toLocaleLowerCase()
  // Lowercasing can change length for a few characters; fall back to exact matching then.
  const exact = haystack.length !== text.length || needle.length !== query.length
  const source = exact ? text : haystack
  const target = exact ? query : needle
  const ranges: FindRange[] = []
  for (let index = source.indexOf(target); index >= 0; index = source.indexOf(target, index + target.length)) {
    ranges.push([index, index + target.length])
  }
  return ranges.length > 0 ? ranges : undefined
}

const ROW_CACHE_LIMIT = 2048

/**
 * Highlights by row. `show` replaces everything (the active match's row, or
 * every row with a match); `clear` removes all. `rangesFor(rowId)` is what
 * `MessageRowContext.highlightRangesFor` returns: a cached per-row signal that
 * changes only when that row's ranges do.
 */
export class FindHighlights {
  readonly #byRow = signal<ReadonlyMap<MessageRowId, FindRanges>>(new Map())
  readonly #rows = new Map<MessageRowId, ReadSignal<FindRanges | undefined>>()

  /** Highlight these rows with these ranges (already normalized), and no others. */
  show(byRow: ReadonlyMap<MessageRowId, FindRanges>): void {
    this.#byRow.set(byRow)
  }

  /** Highlight one row only (the active match). */
  showRow(rowId: MessageRowId, ranges: FindRanges | undefined): void {
    this.#byRow.set(ranges && ranges.length > 0 ? new Map([[rowId, ranges]]) : new Map())
  }

  clear(): void {
    if (this.#byRow.peek().size > 0) this.#byRow.set(new Map())
  }

  /** The rows with ranges now. */
  get rows(): ReadonlySet<MessageRowId> {
    return new Set(this.#byRow.peek().keys())
  }

  rangesFor(rowId: MessageRowId): ReadSignal<FindRanges | undefined> {
    let row = this.#rows.get(rowId)
    if (!row) {
      if (this.#rows.size >= ROW_CACHE_LIMIT) this.#rows.clear()
      row = computed(() => this.#byRow.get().get(rowId), { equals: sameRanges })
      this.#rows.set(rowId, row)
    }
    return row
  }
}
