/**
 * Geometry of the windowed sidebar list. Rows have one fixed height per
 * density (the Mac's `SidebarItemSize.rowHeight`), so every position is
 * arithmetic: no measuring, and an index maps to an offset exactly.
 */

import type { RowKey } from "@inline/core-protocol"

export type SidebarDensity = "compact" | "standard"

export type RowMetrics = {
  /** Height of one row, including the 1 px visual gap (Mac `itemVisualGap`). */
  readonly rowHeight: number
  /** Avatar or icon size (Mac `SidebarItemSize.iconSize`). */
  readonly avatarSize: number
  /** Whether the row shows a second line with the preview. */
  readonly showsPreview: boolean
}

/** Mac `SidebarItemSize`: compact 30 pt with a 22 pt icon, standard 40 pt with a 30 pt icon. */
export const rowMetrics = (density: SidebarDensity): RowMetrics =>
  density === "compact"
    ? { rowHeight: 30, avatarSize: 22, showsPreview: false }
    : { rowHeight: 40, avatarSize: 30, showsPreview: true }

/** Space above the first row and below the last. */
export const LIST_PADDING = 6

/** Rows rendered beyond each edge of the viewport. */
export const DEFAULT_OVERSCAN = 8

export type Viewport = { readonly scrollTop: number; readonly height: number }

/** Rows `first` (inclusive) to `last` (exclusive). */
export type IndexRange = { readonly first: number; readonly last: number }

const clamp = (value: number, min: number, max: number) => Math.min(max, Math.max(min, value))

export const contentHeight = (count: number, rowHeight: number, padding = LIST_PADDING): number =>
  count === 0 ? 0 : count * rowHeight + padding * 2

export const rowTop = (index: number, rowHeight: number, padding = LIST_PADDING): number => padding + index * rowHeight

/** The rows that intersect the viewport, widened by `overscan` on each side. */
export const visibleRange = (
  viewport: Viewport,
  count: number,
  rowHeight: number,
  overscan = DEFAULT_OVERSCAN,
  padding = LIST_PADDING,
): IndexRange => {
  if (count <= 0 || rowHeight <= 0) return { first: 0, last: 0 }
  const top = viewport.scrollTop - padding
  const first = clamp(Math.floor(top / rowHeight) - overscan, 0, count)
  const last = clamp(Math.ceil((top + Math.max(0, viewport.height)) / rowHeight) + overscan, first, count)
  return { first, last }
}

export const sameRange = (a: IndexRange, b: IndexRange): boolean => a.first === b.first && a.last === b.last

/**
 * The keys to render: the range, plus `extra` (the roving focus row) when it
 * lies outside, kept in list order so the DOM order is the list order.
 */
export const windowKeys = (keys: readonly RowKey[], range: IndexRange, extra?: number): readonly RowKey[] => {
  const slice = keys.slice(range.first, range.last)
  if (extra === undefined || extra < 0 || extra >= keys.length) return slice
  if (extra >= range.first && extra < range.last) return slice
  const key = keys[extra]
  if (key === undefined) return slice
  return extra < range.first ? [key, ...slice] : [...slice, key]
}

/**
 * The scroll offset that brings row `index` fully into view with the least
 * movement, or undefined when it is already fully visible.
 */
export const scrollToReveal = (
  index: number,
  viewport: Viewport,
  count: number,
  rowHeight: number,
  padding = LIST_PADDING,
): number | undefined => {
  if (index < 0 || index >= count) return undefined
  const max = Math.max(0, contentHeight(count, rowHeight, padding) - viewport.height)
  const top = rowTop(index, rowHeight, padding)
  const bottom = top + rowHeight
  if (top < viewport.scrollTop) return clamp(top - padding, 0, max)
  if (bottom > viewport.scrollTop + viewport.height) return clamp(bottom + padding - viewport.height, 0, max)
  return undefined
}

/** The first row whose top is at or below the viewport's bottom edge. A row cut by the edge counts as visible. */
export const firstIndexBelow = (viewport: Viewport, rowHeight: number, padding = LIST_PADDING): number =>
  Math.max(0, Math.ceil((viewport.scrollTop + viewport.height - padding) / rowHeight))

/** Index of the first value in ascending `sorted` that is >= `value`. */
export const lowerBound = (sorted: readonly number[], value: number): number => {
  let low = 0
  let high = sorted.length
  while (low < high) {
    const mid = (low + high) >>> 1
    if ((sorted[mid] ?? Infinity) < value) low = mid + 1
    else high = mid
  }
  return low
}

export type UnreadBelow = { readonly count: number; readonly target?: number }

export const NO_UNREAD_BELOW: UnreadBelow = Object.freeze({ count: 0 })

/**
 * Prominent unread rows below the viewport (Mac `unreadBelowViewport`): how
 * many, and the nearest one, which the button scrolls to.
 */
export const unreadBelow = (prominentUnread: readonly number[], firstBelow: number): UnreadBelow => {
  const start = lowerBound(prominentUnread, firstBelow)
  const count = prominentUnread.length - start
  if (count <= 0) return NO_UNREAD_BELOW
  return { count, target: prominentUnread[start] }
}

export const sameUnreadBelow = (a: UnreadBelow, b: UnreadBelow): boolean => a.count === b.count && a.target === b.target

export type UnreadScrollPlan = {
  readonly targetOffset: number
  /** Where to jump first so a long scroll animates over one viewport only. */
  readonly animatedStartOffset: number
  readonly usesLongDistanceJump: boolean
}

/**
 * Mac `SidebarUnreadScrollPlan.resolve`: center the target row, clamped to
 * the content; a move longer than a viewport jumps to one viewport short of
 * the target and animates the rest.
 */
export const unreadScrollPlan = (input: {
  readonly currentOffset: number
  readonly targetTop: number
  readonly targetBottom: number
  readonly viewportHeight: number
  readonly contentHeight: number
}): UnreadScrollPlan => {
  const viewport = Math.max(input.viewportHeight, 0)
  const max = Math.max(input.contentHeight - viewport, 0)
  const current = clamp(input.currentOffset, 0, max)
  const middle = (Math.min(input.targetTop, input.targetBottom) + Math.max(input.targetTop, input.targetBottom)) / 2
  const targetOffset = clamp(middle - viewport / 2, 0, max)
  const delta = targetOffset - current
  const usesLongDistanceJump = viewport > 0 && Math.abs(delta) > viewport
  const start = usesLongDistanceJump ? targetOffset - (delta > 0 ? viewport : -viewport) : current
  return { targetOffset, animatedStartOffset: clamp(start, 0, max), usesLongDistanceJump }
}
