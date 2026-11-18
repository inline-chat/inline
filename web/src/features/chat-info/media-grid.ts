/**
 * Keyboard navigation of the shared-media grid: one roving tab stop over
 * square cells laid out by CSS (`repeat(auto-fill, minmax(100px, 1fr))`,
 * 4 px gaps, the Mac's `GridItem(.adaptive(minimum: 100), spacing: 4)`).
 * Framework-free; the grid element's part measures its columns.
 *
 * Keys: arrows move one cell (Left and Right swap in right to left), Up and
 * Down one row, Home and End to the first and last cell, Page Up and Page
 * Down three rows; Enter and Space open the cell. Reaching the last row asks
 * for the next page. Focus follows the active cell when it moved by key.
 */

import { computed, signal, type ReadSignal } from "@inline/reactive"
import type { Part } from "@inline/ui"

/** The Mac's grid: cells at least 100 px wide with 4 px between them. */
export const MEDIA_CELL_MIN = 100
export const MEDIA_CELL_GAP = 4

/** Columns the CSS grid makes at a width. */
export const columnsFor = (width: number): number => Math.max(1, Math.floor((width + MEDIA_CELL_GAP) / (MEDIA_CELL_MIN + MEDIA_CELL_GAP)))

export type MediaGridOptions = {
  /** Cells, in order. */
  readonly count: ReadSignal<number>
  readonly onOpen: (index: number) => void
  /** The keyboard reached the last row: ask for more. */
  readonly onNearEnd?: () => void
  /** For tests: the observer that measures the grid. Default `ResizeObserver`. */
  readonly observeWidth?: (element: Element, onWidth: (width: number) => void) => () => void
}

export type MediaGrid = ReturnType<typeof createMediaGrid>

const defaultObserveWidth = (element: Element, onWidth: (width: number) => void): (() => void) => {
  const Observer = element.ownerDocument.defaultView?.ResizeObserver
  onWidth(element.getBoundingClientRect().width)
  if (!Observer) return () => {}
  const observer = new Observer((entries) => {
    const entry = entries[entries.length - 1]
    if (entry) onWidth(entry.contentRect.width)
  })
  observer.observe(element)
  return () => observer.disconnect()
}

export const createMediaGrid = (options: MediaGridOptions) => {
  const columns = signal(1)
  const active = signal(0)
  const cells = new Map<number, HTMLElement>()
  let rtl = false

  /** The active index, kept inside the list. */
  const activeIndex = computed(() => Math.max(0, Math.min(active.get(), options.count.get() - 1)))
  const tabStops = new Map<number, ReadSignal<boolean>>()

  const move = (index: number, focus: boolean) => {
    const count = options.count.peek()
    if (count === 0) return
    const next = Math.max(0, Math.min(index, count - 1))
    active.set(next)
    if (Math.floor(next / columns.peek()) >= Math.floor((count - 1) / columns.peek())) options.onNearEnd?.()
    if (focus) cells.get(next)?.focus({ preventScroll: false })
  }

  /** Returns true when the key was used. */
  const handleKey = (key: string): boolean => {
    const count = options.count.peek()
    if (count === 0) return false
    const current = activeIndex.peek()
    const cols = columns.peek()
    switch (key) {
      case "ArrowRight":
        move(current + (rtl ? -1 : 1), true)
        return true
      case "ArrowLeft":
        move(current + (rtl ? 1 : -1), true)
        return true
      case "ArrowDown":
        move(Math.min(current + cols, count - 1), true)
        return true
      case "ArrowUp":
        move(current - cols < 0 ? current : current - cols, true)
        return true
      case "Home":
        move(0, true)
        return true
      case "End":
        move(count - 1, true)
        return true
      case "PageDown":
        move(Math.min(current + cols * 3, count - 1), true)
        return true
      case "PageUp":
        move(Math.max(current - cols * 3, current % cols), true)
        return true
      case "Enter":
      case " ":
        options.onOpen(current)
        return true
      default:
        return false
    }
  }

  /** The grid element: measures columns, takes keys, reads the direction. */
  const root: Part = {
    attach: (element) => {
      const stop = (options.observeWidth ?? defaultObserveWidth)(element, (width) => {
        if (width > 0) columns.set(columnsFor(width))
      })
      const view = element.ownerDocument.defaultView
      rtl = view ? view.getComputedStyle(element).direction === "rtl" : false
      const onKeyDown = (event: Event) => {
        const keyboard = event as KeyboardEvent
        if (keyboard.altKey || keyboard.ctrlKey || keyboard.metaKey) return
        rtl = view ? view.getComputedStyle(element).direction === "rtl" : rtl
        if (handleKey(keyboard.key)) keyboard.preventDefault()
      }
      element.addEventListener("keydown", onKeyDown)
      return () => {
        stop()
        element.removeEventListener("keydown", onKeyDown)
      }
    },
  }

  /** One cell: takes focus when it is the active one and the keyboard moved there. */
  const cell = (index: number): Part => ({
    attach: (element) => {
      cells.set(index, element)
      const onFocus = () => active.set(index)
      element.addEventListener("focus", onFocus)
      return () => {
        element.removeEventListener("focus", onFocus)
        if (cells.get(index) === element) cells.delete(index)
      }
    },
  })

  /** Whether a cell is the tab stop (`tabIndex` 0); one cached computed per index. */
  const isTabStop = (index: number): ReadSignal<boolean> => {
    let cached = tabStops.get(index)
    if (!cached) {
      cached = computed(() => activeIndex.get() === index)
      tabStops.set(index, cached)
    }
    return cached
  }

  return {
    columns: columns as ReadSignal<number>,
    active: activeIndex,
    handleKey,
    /** A click on a cell: make it the tab stop and open it. */
    open: (index: number) => {
      active.set(index)
      options.onOpen(index)
    },
    setColumns: (value: number) => columns.set(Math.max(1, value)),
    setDirection: (value: "ltr" | "rtl") => {
      rtl = value === "rtl"
    },
    root,
    cell,
    isTabStop,
  }
}
