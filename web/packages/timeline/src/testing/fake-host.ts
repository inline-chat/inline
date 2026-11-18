/**
 * A deterministic layout model implementing `TimelineHost`, for tests here
 * and in other packages. Rows are stacked boxes with heights; the viewport
 * has a height, insets and a scroll offset; time and frames are virtual.
 *
 * It follows the order of a browser frame closely enough for drift tests:
 *
 * - `setRows` is a DOM commit. Layout changes at once, and the `rows` event
 *   is delivered synchronously, as the DOM host delivers it from a mutation
 *   observer in the microtask after the commit, before any scroll event.
 * - `resizeRow` changes layout at once; the `resize` entries are delivered
 *   in the next frame, after scroll events and frame callbacks, as a
 *   `ResizeObserver` does.
 * - `setScrollOffset` clamps and rounds to device pixels at once; the
 *   `scroll` event is delivered at the start of the next frame.
 * - User scrolling emits its `input` event synchronously and moves the
 *   offset; its `scroll` event comes in the next frame.
 *
 * Inspect what the user would see with `rowTop(key)` (viewport coordinates)
 * after `frame()`.
 */

import { animateOffset } from "../animate"
import type {
  Activity,
  Clock,
  FrameSource,
  HostEvent,
  HostListener,
  Insets,
  ItemKey,
  RowRect,
  RowSize,
  ScrollAnimation,
  TimelineHost,
  UserInputSource,
} from "../host"

export type FakeRow = RowSize

/**
 * How the engine treats a fractional scroll offset written to `scrollTop`,
 * in units of `1 / devicePixelRatio`:
 * - `round`, `floor`, `ceil`: snapped on write; reading back returns the snapped value.
 * - `none`: kept exactly.
 * - `deferred`: kept exactly on write and when read back, then rounded at the
 *   next frame (an engine that snaps when it commits the scroll).
 */
export type ScrollRounding = "round" | "floor" | "ceil" | "none" | "deferred"

export const SCROLL_ROUNDINGS: readonly ScrollRounding[] = ["round", "floor", "ceil", "none", "deferred"]

export type FakeHostOptions = {
  viewportHeight?: number
  insets?: Insets
  /** Scroll offsets snap to `1 / devicePixelRatio`. 1 snaps to whole pixels. */
  devicePixelRatio?: number
  /** How written offsets snap. Defaults to `round`. */
  scrollRounding?: ScrollRounding
  /** Fixed padding above the first and below the last row. */
  paddingTop?: number
  paddingBottom?: number
  /** Milliseconds per frame. */
  frameMs?: number
  activity?: Activity
}

export type FakeTimelineHost = {
  host: TimelineHost
  clock: Clock
  frames: FrameSource

  /** Replace the rendered rows (a DOM commit). Rows already present keep their height unless given a new one. */
  setRows(rows: readonly FakeRow[]): void
  /** Change row heights now; the observer entries arrive next frame. */
  resizeRows(rows: readonly FakeRow[]): void
  resizeRow(key: ItemKey, height: number): void
  /** Deliver zero-size observer entries next frame, as for rows under a hidden ancestor. Layout does not change. */
  emitZeroSizes(keys: readonly ItemKey[]): void
  resizeViewport(height: number): void
  setInsets(insets: Insets): void
  setActivity(activity: Activity): void

  /** A user scroll by `delta` px (negative: towards older rows). Emits input now, scroll next frame. */
  userScroll(delta: number, source?: UserInputSource): void
  /** Raw user input without movement. */
  userInput(source: UserInputSource, direction?: "up" | "down", held?: boolean): void
  inputEnd(): void
  /** The browser's `scrollend`. */
  scrollEnd(): void

  /** Advance one frame: timers due, scroll event, frame callbacks, observer entries. */
  frame(): void
  /** Advance frames until `ms` have passed. */
  advance(ms: number): void

  offset(): number
  contentHeight(): number
  /** Top of a row in viewport coordinates, or undefined when not rendered. */
  rowTop(key: ItemKey): number | undefined
  keys(): ItemKey[]
  now(): number
  /** Number of scroll offset writes the controller made. */
  writes(): number
  /** Events delivered so far, newest last. */
  events(): readonly HostEvent[]
}

type Timer = { at: number; seq: number; fn: () => void; cancelled: boolean }

export const createFakeHost = (options: FakeHostOptions = {}): FakeTimelineHost => {
  const dpr = options.devicePixelRatio ?? 2
  const rounding = options.scrollRounding ?? "round"
  const frameMs = options.frameMs ?? 16
  const paddingTop = options.paddingTop ?? 0
  const paddingBottom = options.paddingBottom ?? 0
  let viewport = options.viewportHeight ?? 600
  let insets: Insets = options.insets ?? { top: 0, bottom: 0 }
  let activity: Activity = options.activity ?? { visible: true, active: true }

  let rows: FakeRow[] = []
  let tops: number[] = []
  let index = new Map<ItemKey, number>()
  let content = paddingTop + paddingBottom
  let offset = 0
  let writes = 0

  let now = 0
  let seq = 0
  let timers: Timer[] = []
  let frameCallbacks: { fn: (now: number) => void; cancelled: boolean }[] = []
  let scrollPending = false
  let snapPending = false
  let clampPending = false
  let viewportPending = false
  let pendingSizes = new Map<ItemKey, number>()
  const listeners = new Set<HostListener>()
  const log: HostEvent[] = []

  const emit = (event: HostEvent) => {
    log.push(event)
    for (const listener of Array.from(listeners)) listener(event)
  }

  const relayout = () => {
    tops = []
    index = new Map()
    let y = paddingTop
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i]!
      tops[i] = y
      index.set(row.key, i)
      y += row.height
    }
    content = y + paddingBottom
    clampOffset()
  }

  const maxOffset = () => Math.max(0, content - viewport)
  const round = (value: number) => Math.round(value * dpr) / dpr
  const snap = (value: number) => {
    switch (rounding) {
      case "floor":
        return Math.floor(value * dpr) / dpr
      case "ceil":
        return Math.ceil(value * dpr) / dpr
      case "none":
      case "deferred":
        return value
      default:
        return round(value)
    }
  }
  /**
   * Layout clamps the offset of a list that got shorter. A browser dispatches
   * that scroll event in the frame after the one whose layout clamped it,
   * so the resize observer of this frame runs first.
   */
  const clampOffset = () => {
    const clamped = Math.min(offset, round(maxOffset()))
    if (clamped !== offset) {
      offset = Math.max(0, clamped)
      clampPending = true
    }
  }
  const moveTo = (value: number) => {
    const max = maxOffset()
    let next = snap(Math.min(Math.max(0, value), max))
    if (next > max) next = Math.floor(max * dpr) / dpr
    if (rounding === "deferred") snapPending = true
    if (next !== offset) {
      offset = next
      scrollPending = true
    }
  }

  const clock: Clock = {
    now: () => now,
    setTimeout: (fn, ms) => {
      const timer: Timer = { at: now + Math.max(0, ms), seq: seq++, fn, cancelled: false }
      timers.push(timer)
      return () => {
        timer.cancelled = true
      }
    },
  }

  const frames: FrameSource = {
    request: (fn) => {
      const entry = { fn, cancelled: false }
      frameCallbacks.push(entry)
      return () => {
        entry.cancelled = true
      }
    },
  }

  const rowRect = (key: ItemKey): RowRect | undefined => {
    const i = index.get(key)
    if (i === undefined) return undefined
    const top = tops[i]! - offset
    return { top, bottom: top + rows[i]!.height }
  }

  const host: TimelineHost = {
    viewportHeight: () => viewport,
    contentHeight: () => content,
    scrollOffset: () => offset,
    insets: () => insets,
    rowKeys: () => rows.map((row) => row.key),
    rowRect,
    visibleKeys: () => {
      const out: ItemKey[] = []
      for (let i = 0; i < rows.length; i++) {
        const top = tops[i]! - offset
        const bottom = top + rows[i]!.height
        if (bottom > 0 && top < viewport) out.push(rows[i]!.key)
      }
      return out
    },
    activity: () => activity,
    setScrollOffset: (value) => {
      writes++
      moveTo(value)
    },
    animateScroll: (to: number, animation: ScrollAnimation, done: () => void) =>
      animateOffset(frames, clock, () => offset, (value) => {
        writes++
        moveTo(value)
      }, to, animation, done),
    subscribe: (listener) => {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
  }

  const runTimers = () => {
    for (;;) {
      const due = timers
        .filter((timer) => !timer.cancelled && timer.at <= now)
        .sort((a, b) => a.at - b.at || a.seq - b.seq)[0]
      if (!due) break
      due.cancelled = true
      due.fn()
    }
    timers = timers.filter((timer) => !timer.cancelled)
  }

  const frame = () => {
    now += frameMs
    runTimers()
    if (snapPending) {
      snapPending = false
      const snapped = Math.min(round(offset), Math.floor(maxOffset() * dpr) / dpr)
      if (snapped !== offset) {
        offset = snapped
        scrollPending = true
      }
    }
    if (scrollPending) {
      scrollPending = false
      emit({ kind: "scroll" })
    }
    const callbacks = frameCallbacks
    frameCallbacks = []
    for (const entry of callbacks) if (!entry.cancelled) entry.fn(now)
    // One observer callback: row sizes first, so the viewport event sees a settled size cache.
    if (pendingSizes.size > 0) {
      const batch = [...pendingSizes].map(([key, height]) => ({ key, height }))
      pendingSizes = new Map()
      emit({ kind: "resize", rows: batch })
    }
    if (viewportPending) {
      viewportPending = false
      emit({ kind: "viewport" })
    }
    if (clampPending) {
      clampPending = false
      scrollPending = true
    }
  }

  const fake: FakeTimelineHost = {
    host,
    clock,
    frames,
    setRows: (next) => {
      const before = new Map(rows.map((row) => [row.key, row.height]))
      const measured: RowSize[] = []
      rows = next.map((row) => {
        const old = before.get(row.key)
        if (old === undefined) measured.push({ key: row.key, height: row.height })
        else if (old !== row.height) pendingSizes.set(row.key, row.height)
        return { key: row.key, height: row.height }
      })
      for (const key of pendingSizes.keys()) if (!rows.some((row) => row.key === key)) pendingSizes.delete(key)
      relayout()
      emit({ kind: "rows", keys: rows.map((row) => row.key), measured })
    },
    resizeRows: (changes) => {
      for (const change of changes) {
        const i = index.get(change.key)
        if (i === undefined) continue
        rows[i] = { key: change.key, height: change.height }
        pendingSizes.set(change.key, change.height)
      }
      relayout()
    },
    resizeRow: (key, height) => fake.resizeRows([{ key, height }]),
    emitZeroSizes: (keys) => {
      for (const key of keys) pendingSizes.set(key, 0)
    },
    resizeViewport: (height) => {
      viewport = height
      clampOffset()
      viewportPending = true
    },
    setInsets: (next) => {
      insets = next
      viewportPending = true
    },
    setActivity: (next) => {
      activity = next
      emit({ kind: "activity", ...next })
    },
    userScroll: (delta, source = "wheel") => {
      emit({ kind: "input", source, direction: delta < 0 ? "up" : "down" })
      moveTo(offset + delta)
    },
    userInput: (source, direction, held) => {
      emit({
        kind: "input",
        source,
        ...(direction ? { direction } : {}),
        ...(held ? { held } : {}),
      })
    },
    inputEnd: () => emit({ kind: "inputEnd" }),
    scrollEnd: () => emit({ kind: "scrollEnd" }),
    frame,
    advance: (ms) => {
      const until = now + ms
      while (now < until) frame()
    },
    offset: () => offset,
    contentHeight: () => content,
    rowTop: (key) => rowRect(key)?.top,
    keys: () => rows.map((row) => row.key),
    now: () => now,
    writes: () => writes,
    events: () => log,
  }
  return fake
}
