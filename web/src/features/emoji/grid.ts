/**
 * The emoji grid's geometry and keyboard model, framework-free and DOM-free.
 *
 * - Layout: sections of fixed-size rows, each with an optional header, laid
 *   out top to bottom, so the virtualized view renders only the rows that
 *   intersect the viewport and positions them from `top`.
 * - Movement: arrow keys flow across sections keeping the column where they
 *   can, as the Mac picker does (`EmojiPickerPopover2.swift`
 *   `EmojiPicker2RootView.indexPath(after:moving:columns:counts:)`, lines
 *   689-736); Home, End, Ctrl+Home, Ctrl+End, Page Up and Page Down follow the
 *   WAI-ARIA grid pattern. Directions here are logical (`previous`, `next`);
 *   the caller maps arrow keys by the writing direction.
 * - Metrics are the Mac's `EmojiPicker2Layout` (lines 1602-1627).
 */

export type GridPosition = { readonly section: number; readonly item: number }

export type GridMove = "previous" | "next" | "up" | "down" | "rowStart" | "rowEnd" | "first" | "last" | "pageUp" | "pageDown"

export const GRID_METRICS = {
  /** Popover width (`EmojiPicker2Layout.width`). */
  width: 320,
  /** Cell size (`itemSize`) and the gap between cells (`itemSpacing`). */
  cell: 34,
  gap: 2,
  headerHeight: 28,
  minInset: 12,
  sectionBottomInset: 8,
  searchTopInset: 8,
  preferredColumns: 8,
} as const

export type GridMetrics = typeof GRID_METRICS

/** Row pitch: a cell and the gap below it. */
export const rowPitch = (metrics: GridMetrics = GRID_METRICS) => metrics.cell + metrics.gap

/** Columns that fit a width, at most the preferred eight (`EmojiPicker2Layout.columnCount`). */
export const columnsFor = (width: number, metrics: GridMetrics = GRID_METRICS): number => {
  const available = Math.max(1, width - metrics.minInset * 2)
  const fitted = Math.floor((available + metrics.gap) / (metrics.cell + metrics.gap))
  return Math.max(1, Math.min(metrics.preferredColumns, fitted))
}

/** The inline inset that centers the columns (`collectionSectionInset`). */
export const insetFor = (width: number, columns: number, metrics: GridMetrics = GRID_METRICS): number => {
  const rowWidth = columns * metrics.cell + Math.max(0, columns - 1) * metrics.gap
  return Math.max(metrics.minInset, Math.floor((width - rowWidth) / 2))
}

export type GridRow =
  | { readonly kind: "header"; readonly key: string; readonly section: number; readonly top: number; readonly height: number }
  | {
      readonly kind: "cells"
      readonly key: string
      readonly section: number
      /** Index of the first item in the row. */
      readonly start: number
      readonly count: number
      readonly top: number
      readonly height: number
    }

export type GridSectionInput = { readonly key: string; readonly count: number; readonly header: boolean }

export type GridLayout = {
  readonly columns: number
  readonly rows: readonly GridRow[]
  /** Total content height. */
  readonly height: number
  /** Rows that hold cells, for `aria-rowcount`. */
  readonly cellRowCount: number
  /** Per section: its header's top (or first row's top without a header) and the index of its first row. */
  readonly sections: readonly { readonly top: number; readonly firstRow: number; readonly count: number }[]
}

export const layoutGrid = (sections: readonly GridSectionInput[], columns: number, options: { topInset?: number; metrics?: GridMetrics } = {}): GridLayout => {
  const metrics = options.metrics ?? GRID_METRICS
  const pitch = rowPitch(metrics)
  const rows: GridRow[] = []
  const sectionInfo: { top: number; firstRow: number; count: number }[] = []
  let top = options.topInset ?? 0
  let cellRowCount = 0
  sections.forEach((section, index) => {
    sectionInfo.push({ top, firstRow: rows.length, count: section.count })
    if (section.count === 0) return
    if (section.header) {
      rows.push({ kind: "header", key: `${section.key}:h`, section: index, top, height: metrics.headerHeight })
      top += metrics.headerHeight
    }
    for (let start = 0; start < section.count; start += columns) {
      rows.push({ kind: "cells", key: `${section.key}:${start}`, section: index, start, count: Math.min(columns, section.count - start), top, height: pitch })
      top += pitch
      cellRowCount += 1
    }
    top += metrics.sectionBottomInset
  })
  return { columns, rows, height: top, cellRowCount, sections: sectionInfo }
}

/** The first row whose bottom is below `y` (binary search). */
const rowAt = (rows: readonly GridRow[], y: number): number => {
  let low = 0
  let high = rows.length - 1
  let found = rows.length
  while (low <= high) {
    const mid = (low + high) >> 1
    const row = rows[mid] as GridRow
    if (row.top + row.height > y) {
      found = mid
      high = mid - 1
    } else {
      low = mid + 1
    }
  }
  return found
}

/** The rows to render for a scroll position: `[start, end)`, with `overscan` extra rows on each side. */
export const visibleRows = (layout: GridLayout, scrollTop: number, viewportHeight: number, overscan = 2): { start: number; end: number } => {
  if (layout.rows.length === 0) return { start: 0, end: 0 }
  const first = rowAt(layout.rows, Math.max(0, scrollTop))
  const last = rowAt(layout.rows, scrollTop + Math.max(0, viewportHeight))
  return { start: Math.max(0, first - overscan), end: Math.min(layout.rows.length, Math.max(first, last) + 1 + overscan) }
}

/** The row index (into `layout.rows`) holding a cell. */
export const rowIndexOf = (layout: GridLayout, position: GridPosition): number => {
  const section = layout.sections[position.section]
  if (!section) return -1
  const firstCells = layout.rows[section.firstRow]?.kind === "header" ? section.firstRow + 1 : section.firstRow
  return firstCells + Math.floor(position.item / layout.columns)
}

/**
 * Where to scroll so a cell is visible, or undefined when it already is
 * (`scrollToHighlight`, lines 664-687). Moving onto a section's first row
 * reveals its header too.
 */
export const scrollTargetFor = (
  layout: GridLayout,
  position: GridPosition,
  scrollTop: number,
  viewportHeight: number,
  metrics: GridMetrics = GRID_METRICS,
): number | undefined => {
  const row = layout.rows[rowIndexOf(layout, position)]
  if (!row) return undefined
  const padding = metrics.gap + 4
  let target: number
  if (row.top - padding < scrollTop) {
    const previous = layout.rows[rowIndexOf(layout, position) - 1]
    const header = previous?.kind === "header" && position.item < layout.columns ? previous.height : 0
    target = row.top - padding - header
  } else if (row.top + row.height + padding > scrollTop + viewportHeight) {
    target = row.top + row.height + padding - viewportHeight
  } else {
    return undefined
  }
  return Math.max(0, Math.min(Math.max(0, layout.height - viewportHeight), target))
}

/** Where a section starts, for the category tabs (`scrollToSection`): its header, or the top for the first. */
export const sectionScrollTop = (layout: GridLayout, section: number, viewportHeight: number): number => {
  if (section <= 0) return 0
  const top = layout.sections[section]?.top ?? 0
  return Math.max(0, Math.min(Math.max(0, layout.height - viewportHeight), top))
}

/**
 * The section the viewport shows (`updateActiveTab`, lines 738-765): the last
 * whose header has reached the top, or the last section at the bottom.
 */
export const sectionAtScroll = (layout: GridLayout, scrollTop: number, viewportHeight: number, metrics: GridMetrics = GRID_METRICS): number => {
  if (layout.sections.length === 0) return -1
  const reachedBottom = scrollTop > 0 && scrollTop + viewportHeight >= layout.height - 1
  if (reachedBottom) return layout.sections.length - 1
  let active = 0
  layout.sections.forEach((section, index) => {
    if (section.count > 0 && section.top <= scrollTop + metrics.headerHeight) active = index
  })
  return active
}

/**
 * The cell a move lands on, or undefined when it cannot move. `counts` are
 * the item counts of each section; empty sections are skipped.
 */
export const moveInGrid = (
  current: GridPosition,
  move: GridMove,
  columns: number,
  counts: readonly number[],
  pageRows = 1,
): GridPosition | undefined => {
  const { section, item } = current
  const count = counts[section]
  if (count === undefined || columns <= 0 || item < 0 || item >= count) return undefined

  const previousSection = (from: number) => {
    for (let index = from - 1; index >= 0; index--) if ((counts[index] ?? 0) > 0) return index
    return undefined
  }
  const nextSection = (from: number) => {
    for (let index = from + 1; index < counts.length; index++) if ((counts[index] ?? 0) > 0) return index
    return undefined
  }

  switch (move) {
    case "next": {
      if (item + 1 < count) return { section, item: item + 1 }
      const next = nextSection(section)
      return next === undefined ? undefined : { section: next, item: 0 }
    }
    case "previous": {
      if (item > 0) return { section, item: item - 1 }
      const previous = previousSection(section)
      return previous === undefined ? undefined : { section: previous, item: (counts[previous] ?? 1) - 1 }
    }
    case "down": {
      if (item + columns < count) return { section, item: item + columns }
      const lastRowStart = Math.floor((count - 1) / columns) * columns
      if (item < lastRowStart) return { section, item: count - 1 }
      const next = nextSection(section)
      return next === undefined ? undefined : { section: next, item: Math.min(item % columns, (counts[next] ?? 1) - 1) }
    }
    case "up": {
      if (item - columns >= 0) return { section, item: item - columns }
      const previous = previousSection(section)
      if (previous === undefined) return undefined
      const previousCount = counts[previous] ?? 1
      const lastRowStart = Math.floor((previousCount - 1) / columns) * columns
      return { section: previous, item: Math.min(lastRowStart + (item % columns), previousCount - 1) }
    }
    case "rowStart":
      return { section, item: item - (item % columns) }
    case "rowEnd":
      return { section, item: Math.min(count - 1, item - (item % columns) + columns - 1) }
    case "first": {
      const firstSection = (counts[0] ?? 0) > 0 ? 0 : nextSection(0)
      return firstSection === undefined ? undefined : { section: firstSection, item: 0 }
    }
    case "last": {
      const lastSection = (counts[counts.length - 1] ?? 0) > 0 ? counts.length - 1 : previousSection(counts.length - 1)
      return lastSection === undefined ? undefined : { section: lastSection, item: (counts[lastSection] ?? 1) - 1 }
    }
    case "pageDown":
    case "pageUp": {
      let position: GridPosition = current
      for (let step = 0; step < Math.max(1, pageRows); step++) {
        const next = moveInGrid(position, move === "pageDown" ? "down" : "up", columns, counts)
        if (!next) break
        position = next
      }
      return position === current ? undefined : position
    }
  }
}

/** Arrow keys and grid keys to moves. Left and right follow the writing direction. */
export const gridMoveForKey = (
  key: string,
  options: { readonly rtl?: boolean; readonly ctrl?: boolean },
): GridMove | undefined => {
  switch (key) {
    case "ArrowRight":
      return options.rtl ? "previous" : "next"
    case "ArrowLeft":
      return options.rtl ? "next" : "previous"
    case "ArrowDown":
      return "down"
    case "ArrowUp":
      return "up"
    case "Home":
      return options.ctrl ? "first" : "rowStart"
    case "End":
      return options.ctrl ? "last" : "rowEnd"
    case "PageDown":
      return "pageDown"
    case "PageUp":
      return "pageUp"
    default:
      return undefined
  }
}

export const samePosition = (a: GridPosition | null | undefined, b: GridPosition | null | undefined): boolean =>
  a === b || (!!a && !!b && a.section === b.section && a.item === b.item)
