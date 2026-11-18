/**
 * The host interface: the few DOM facts the timeline controller reads and the
 * few commands it issues. `dom-host.ts` implements it over a scroll container;
 * `testing/fake-host.ts` implements it over a deterministic layout model so
 * the controller is tested in Node.
 *
 * Coordinates. The list is top-down: offset 0 shows the oldest rendered row,
 * the newest row is at the bottom. `scrollOffset` runs from 0 to
 * `contentHeight - viewportHeight`. Row rectangles are in viewport
 * coordinates: 0 is the top edge of the scroll container's visible box, so a
 * row's `top` does not depend on how the host reads `scrollTop`.
 *
 * Rows are direct children of one content element, in reading order, keyed by
 * timeline item key. Rows have no vertical margins (spacing lives inside a
 * row), so the content height is the sum of row heights plus fixed padding.
 * The controller relies on that to compensate from row heights alone.
 */

/** A timeline item key; see `items.ts`. */
export type ItemKey = string

/** A row's vertical extent in viewport coordinates. */
export type RowRect = { top: number; bottom: number }

export type RowSize = { key: ItemKey; height: number }

/**
 * Parts of the viewport covered by overlays (a translucent header above, the
 * composer below). Anchors, landings and read marking use the uncovered part.
 */
export type Insets = { top: number; bottom: number }

/** Timing curves of the Mac's jumps (Core Animation's named functions). */
export type Easing = "linear" | "easeIn" | "easeOut" | "easeInOut"

export type ScrollAnimation = { duration: number; easing: Easing }

export type UserInputSource = "wheel" | "touch" | "key" | "scrollbar"

export type Activity = {
  /** The document is visible (not a background tab, not minimized). */
  visible: boolean
  /** The window has focus (the app is active). */
  active: boolean
}

export type HostEvent =
  /**
   * User scroll input, before any scroll it causes. `direction` is the way
   * the content would move through the list: "up" towards older rows. `held`
   * marks a gesture that continues until `inputEnd` (a touch, a scrollbar
   * drag).
   */
  | { kind: "input"; source: UserInputSource; direction?: "up" | "down"; held?: boolean }
  | { kind: "inputEnd" }
  /** The scroll offset changed, for any reason. */
  | { kind: "scroll" }
  /** Scrolling settled (`scrollend`, or the host's fallback). */
  | { kind: "scrollEnd" }
  /**
   * The rendered rows changed structurally. Delivered before the browser
   * paints and before any later scroll event: the DOM host emits it from a
   * mutation observer, in the microtask after the commit. `keys` is the new
   * order; `measured` has the height of every row that is new.
   */
  | { kind: "rows"; keys: readonly ItemKey[]; measured: readonly RowSize[] }
  /** Row sizes changed, batched per frame. Zero-size entries may be included; the controller ignores them. */
  | { kind: "resize"; rows: readonly RowSize[] }
  /** The viewport's size or the insets changed. */
  | { kind: "viewport" }
  | ({ kind: "activity" } & Activity)

export type HostListener = (event: HostEvent) => void

export interface TimelineHost {
  viewportHeight(): number
  contentHeight(): number
  scrollOffset(): number
  insets(): Insets
  /** Keys of every rendered row, in reading order. Read when the controller attaches. */
  rowKeys(): ItemKey[]
  /** The rectangle of a rendered row, or undefined when it is not rendered. */
  rowRect(key: ItemKey): RowRect | undefined
  /** Keys of the rows intersecting the viewport, in reading order. */
  visibleKeys(): ItemKey[]
  activity(): Activity
  /** Write the scroll offset. The host clamps and may round it; it never emits user input for it. */
  setScrollOffset(offset: number): void
  /**
   * Animate the scroll offset to `to`. `done` runs when the animation
   * finishes, not when it is cancelled. Returns the cancel function, which
   * leaves the offset where it is.
   */
  animateScroll(to: number, animation: ScrollAnimation, done: () => void): () => void
  subscribe(listener: HostListener): () => void
}

/** Injected time, so tests run on a virtual clock. Milliseconds. */
export interface Clock {
  now(): number
  setTimeout(fn: () => void, ms: number): () => void
}

/** Injected frames (`requestAnimationFrame` in a browser). */
export interface FrameSource {
  request(fn: (now: number) => void): () => void
}

export const browserClock: Clock = {
  now: () => performance.now(),
  setTimeout: (fn, ms) => {
    const id = globalThis.setTimeout(fn, ms)
    return () => globalThis.clearTimeout(id)
  },
}

export const browserFrames: FrameSource = {
  request: (fn) => {
    const id = globalThis.requestAnimationFrame(fn)
    return () => globalThis.cancelAnimationFrame(id)
  },
}
