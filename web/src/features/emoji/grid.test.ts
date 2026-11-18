/**
 * The grid's keyboard model and geometry. Movement is the Mac picker's
 * `EmojiPicker2RootView.indexPath(after:moving:columns:counts:)`
 * (`apple/InlineMac/Views/Components/EmojiPickerPopover2.swift` lines 689-736);
 * Home, End and paging are the WAI-ARIA grid pattern's.
 */

import { describe, expect, it } from "vitest"
import {
  columnsFor,
  GRID_METRICS,
  gridMoveForKey,
  insetFor,
  layoutGrid,
  moveInGrid,
  rowIndexOf,
  scrollTargetFor,
  sectionAtScroll,
  sectionScrollTop,
  visibleRows,
} from "./grid"

// Sections of 10, 0 (empty, skipped) and 5 items, 4 columns.
const counts = [10, 0, 5]
const move = (section: number, item: number, direction: Parameters<typeof moveInGrid>[1], pageRows?: number) =>
  moveInGrid({ section, item }, direction, 4, counts, pageRows)

describe("moving in the grid (Mac lines 689-736)", () => {
  it("next and previous flow across sections, skipping empty ones", () => {
    expect(move(0, 3, "next")).toEqual({ section: 0, item: 4 })
    expect(move(0, 9, "next")).toEqual({ section: 2, item: 0 })
    expect(move(2, 0, "previous")).toEqual({ section: 0, item: 9 })
    expect(move(0, 0, "previous")).toBeUndefined()
    expect(move(2, 4, "next")).toBeUndefined()
  })

  it("down keeps the column, lands on the last item of a short last row, then enters the next section", () => {
    expect(move(0, 1, "down")).toEqual({ section: 0, item: 5 })
    // Row 2 holds 8 and 9: from 6 (row 1) down goes to the last item, 9.
    expect(move(0, 6, "down")).toEqual({ section: 0, item: 9 })
    // From the last row, the column carries into the next section.
    expect(move(0, 9, "down")).toEqual({ section: 2, item: 1 })
    expect(move(0, 8, "down")).toEqual({ section: 2, item: 0 })
    expect(move(2, 4, "down")).toBeUndefined()
  })

  it("up keeps the column and enters the previous section's last row", () => {
    expect(move(0, 5, "up")).toEqual({ section: 0, item: 1 })
    expect(move(2, 1, "up")).toEqual({ section: 0, item: 9 })
    expect(move(2, 3, "up")).toEqual({ section: 0, item: 9 })
    expect(move(2, 0, "up")).toEqual({ section: 0, item: 8 })
    expect(move(0, 2, "up")).toBeUndefined()
  })

  it("Home, End, Ctrl+Home, Ctrl+End (APG grid)", () => {
    expect(move(0, 6, "rowStart")).toEqual({ section: 0, item: 4 })
    expect(move(0, 5, "rowEnd")).toEqual({ section: 0, item: 7 })
    expect(move(0, 9, "rowEnd")).toEqual({ section: 0, item: 9 })
    expect(move(2, 3, "first")).toEqual({ section: 0, item: 0 })
    expect(move(0, 3, "last")).toEqual({ section: 2, item: 4 })
  })

  it("Page Up and Page Down move by rows and stop at the ends", () => {
    expect(move(0, 1, "pageDown", 2)).toEqual({ section: 0, item: 9 })
    expect(move(0, 1, "pageDown", 3)).toEqual({ section: 2, item: 1 })
    expect(move(2, 1, "pageUp", 10)).toEqual({ section: 0, item: 1 })
    expect(move(0, 1, "pageUp", 2)).toBeUndefined()
  })

  it("refuses a position outside the data", () => {
    expect(moveInGrid({ section: 5, item: 0 }, "next", 4, counts)).toBeUndefined()
    expect(moveInGrid({ section: 0, item: 10 }, "next", 4, counts)).toBeUndefined()
    expect(moveInGrid({ section: 0, item: 0 }, "next", 0, counts)).toBeUndefined()
  })

  it("maps keys, mirroring left and right in right-to-left", () => {
    expect(gridMoveForKey("ArrowRight", {})).toBe("next")
    expect(gridMoveForKey("ArrowRight", { rtl: true })).toBe("previous")
    expect(gridMoveForKey("ArrowLeft", { rtl: true })).toBe("next")
    expect(gridMoveForKey("Home", {})).toBe("rowStart")
    expect(gridMoveForKey("Home", { ctrl: true })).toBe("first")
    expect(gridMoveForKey("End", { ctrl: true })).toBe("last")
    expect(gridMoveForKey("PageDown", {})).toBe("pageDown")
    expect(gridMoveForKey("a", {})).toBeUndefined()
  })
})

describe("geometry (EmojiPicker2Layout)", () => {
  it("fits eight columns in the 320 px picker, fewer when narrow", () => {
    expect(columnsFor(320)).toBe(8)
    expect(columnsFor(200)).toBe(4)
    expect(columnsFor(10)).toBe(1)
    expect(insetFor(320, 8)).toBe(17)
  })

  it("lays out headers, rows of cells and section insets", () => {
    const layout = layoutGrid(
      [
        { key: "a", count: 10, header: true },
        { key: "b", count: 0, header: true },
        { key: "c", count: 5, header: true },
      ],
      4,
    )
    expect(layout.rows.map((row) => row.kind)).toEqual(["header", "cells", "cells", "cells", "header", "cells", "cells"])
    expect(layout.cellRowCount).toBe(5)
    const pitch = GRID_METRICS.cell + GRID_METRICS.gap
    const sectionA = GRID_METRICS.headerHeight + 3 * pitch + GRID_METRICS.sectionBottomInset
    expect(layout.rows[4]?.top).toBe(sectionA)
    expect(layout.height).toBe(sectionA * 2 - pitch)
    expect(rowIndexOf(layout, { section: 2, item: 4 })).toBe(6)
    expect(rowIndexOf(layout, { section: 0, item: 0 })).toBe(1)
  })

  it("renders only the rows in view, with overscan", () => {
    const layout = layoutGrid([{ key: "all", count: 1898, header: false }], 8)
    expect(layout.rows).toHaveLength(238)
    const range = visibleRows(layout, 3600, 292, 2)
    // 292 px shows about nine 36 px rows; with two above and below, about thirteen.
    expect(range.end - range.start).toBeLessThanOrEqual(14)
    expect(range.start).toBe(98)
    expect(visibleRows(layoutGrid([], 8), 0, 300)).toEqual({ start: 0, end: 0 })
  })

  it("scrolls the least to reveal a cell, showing the header on a section's first row (Mac lines 664-687)", () => {
    const layout = layoutGrid(
      [
        { key: "a", count: 80, header: true },
        { key: "b", count: 160, header: true },
      ],
      8,
    )
    // Already visible: no scroll.
    expect(scrollTargetFor(layout, { section: 0, item: 0 }, 0, 292)).toBeUndefined()
    // Below the viewport: scroll so its bottom (and padding) is at the bottom.
    const row9 = layout.rows[rowIndexOf(layout, { section: 0, item: 72 })]
    expect(scrollTargetFor(layout, { section: 0, item: 72 }, 0, 292)).toBe((row9?.top ?? 0) + (row9?.height ?? 0) + 6 - 292)
    // Up onto a section's first row: its header comes into view too.
    const first = layout.rows[rowIndexOf(layout, { section: 1, item: 0 })]
    expect(scrollTargetFor(layout, { section: 1, item: 0 }, 2000, 292)).toBe((first?.top ?? 0) - 6 - GRID_METRICS.headerHeight)
  })

  it("tracks the section in view and scrolls to a section's header (updateActiveTab, scrollToSection)", () => {
    const layout = layoutGrid(
      [
        { key: "a", count: 80, header: true },
        { key: "b", count: 80, header: true },
        { key: "c", count: 8, header: true },
      ],
      8,
    )
    expect(sectionAtScroll(layout, 0, 292)).toBe(0)
    const second = layout.sections[1]?.top ?? 0
    expect(sectionAtScroll(layout, second, 292)).toBe(1)
    expect(sectionAtScroll(layout, layout.height - 292, 292)).toBe(2)
    expect(sectionScrollTop(layout, 0, 292)).toBe(0)
    expect(sectionScrollTop(layout, 1, 292)).toBe(second)
    expect(sectionScrollTop(layout, 2, 292)).toBe(layout.height - 292)
  })
})
