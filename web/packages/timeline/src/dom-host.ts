/**
 * The timeline host over a real scroll container.
 *
 * - The container is the scroll element. Rows are the direct children of
 *   `content` (the container itself by default) that carry the key attribute,
 *   in reading order, with no vertical margins.
 * - `overflow-anchor: none` is set on the container, so the browser's own
 *   scroll anchoring never fights the controller (it is also missing in
 *   older Safari, so it cannot be relied on).
 * - Structural changes are reported from a `MutationObserver`: its callback
 *   runs in the microtask after the commit, before the frame paints and
 *   before any later scroll event. New rows are measured there (one layout
 *   read) so the controller corrects a prepend in the same frame.
 * - Size changes come from one `ResizeObserver`, which already delivers once
 *   per frame after layout. Rows under a hidden ancestor report zero sizes;
 *   the controller ignores them.
 * - User input is classified from wheel, touch, key and pointer events and
 *   reported before the scroll it causes. A scroll during a pointer press on
 *   the container (scrollbar drag, including overlay scrollbars, or drag
 *   selection auto-scroll) counts as scrollbar input.
 * - `scrollend` is forwarded where supported; elsewhere scrolling ends
 *   `SCROLL_IDLE_MS` after the last scroll event.
 *
 * Layout is only read inside the host's queries and the observer callbacks,
 * and the controller writes the offset after its reads.
 */

import { animateOffset } from "./animate"
import { SCROLL_IDLE_MS } from "./constants"
import {
  browserClock,
  browserFrames,
  type Activity,
  type Clock,
  type FrameSource,
  type HostEvent,
  type HostListener,
  type Insets,
  type ItemKey,
  type RowRect,
  type RowSize,
  type TimelineHost,
} from "./host"

export type DomHostOptions = {
  /** The element whose direct children are the rows. Defaults to the container. */
  content?: HTMLElement
  /** Attribute carrying each row's item key. */
  keyAttribute?: string
  /** Overlays covering the viewport. Call `notifyInsets` when they change. */
  insets?: () => Insets
  clock?: Clock
  frames?: FrameSource
}

export type DomHost = TimelineHost & {
  /** The insets changed (a composer grew, a header appeared). */
  notifyInsets(): void
  dispose(): void
}

export const DEFAULT_KEY_ATTRIBUTE = "data-timeline-key"

const UP_KEYS = new Set(["ArrowUp", "PageUp", "Home"])
const DOWN_KEYS = new Set(["ArrowDown", "PageDown", "End"])

const isEditable = (target: EventTarget | null): boolean => {
  if (!target || typeof (target as Element).closest !== "function") return false
  const element = target as HTMLElement
  if (element.isContentEditable) return true
  return element.closest("input, textarea, select, [contenteditable]:not([contenteditable='false'])") !== null
}

export const createDomHost = (container: HTMLElement, options: DomHostOptions = {}): DomHost => {
  const content = options.content ?? container
  const keyAttribute = options.keyAttribute ?? DEFAULT_KEY_ATTRIBUTE
  const clock = options.clock ?? browserClock
  const frames = options.frames ?? browserFrames
  const doc = container.ownerDocument
  const view = doc.defaultView
  const insets = options.insets ?? (() => ({ top: 0, bottom: 0 }))

  container.style.setProperty("overflow-anchor", "none")

  const listeners = new Set<HostListener>()
  const emit = (event: HostEvent) => {
    for (const listener of Array.from(listeners)) listener(event)
  }

  // -------------------------------------------------------------------------
  // Rows

  let order: HTMLElement[] = []
  let byKey = new Map<ItemKey, HTMLElement>()
  const keyOf = (element: Element) => element.getAttribute(keyAttribute)

  const readRows = () => {
    const nextOrder: HTMLElement[] = []
    const nextByKey = new Map<ItemKey, HTMLElement>()
    for (const child of Array.from(content.children)) {
      const key = keyOf(child)
      if (key === null) continue
      nextOrder.push(child as HTMLElement)
      nextByKey.set(key, child as HTMLElement)
    }
    return { nextOrder, nextByKey }
  }

  const ResizeObserverClass = view?.ResizeObserver ?? globalThis.ResizeObserver
  const resizeObserver =
    typeof ResizeObserverClass === "function"
      ? new ResizeObserverClass((entries) => {
          let viewportChanged = false
          const rows: RowSize[] = []
          for (const entry of entries) {
            if (entry.target === container) {
              viewportChanged = true
              continue
            }
            if (!entry.target.isConnected) continue
            const key = keyOf(entry.target)
            if (key === null || byKey.get(key) !== entry.target) continue
            const box = entry.borderBoxSize?.[0]
            rows.push({ key, height: box ? box.blockSize : entry.contentRect.height })
          }
          // Row sizes first, so the viewport event sees a settled size cache.
          if (rows.length) emit({ kind: "resize", rows })
          if (viewportChanged) emit({ kind: "viewport" })
        })
      : undefined

  {
    const { nextOrder, nextByKey } = readRows()
    order = nextOrder
    byKey = nextByKey
    resizeObserver?.observe(container)
    for (const element of order) resizeObserver?.observe(element)
  }

  const MutationObserverClass = view?.MutationObserver ?? globalThis.MutationObserver
  const mutationObserver = new MutationObserverClass(() => {
    const { nextOrder, nextByKey } = readRows()
    const measured: RowSize[] = []
    for (const [key, element] of nextByKey) {
      if (byKey.get(key) === element) continue
      resizeObserver?.observe(element)
      measured.push({ key, height: element.getBoundingClientRect().height })
    }
    for (const [key, element] of byKey) {
      if (nextByKey.get(key) !== element) resizeObserver?.unobserve(element)
    }
    order = nextOrder
    byKey = nextByKey
    emit({ kind: "rows", keys: order.map((element) => keyOf(element)!), measured })
  })
  mutationObserver.observe(content, { childList: true })

  // -------------------------------------------------------------------------
  // Geometry

  const viewportBox = () => {
    const rect = container.getBoundingClientRect()
    const top = rect.top + container.clientTop
    return { top, bottom: top + container.clientHeight }
  }

  const rowRect = (key: ItemKey): RowRect | undefined => {
    const element = byKey.get(key)
    if (!element) return undefined
    const box = viewportBox()
    const rect = element.getBoundingClientRect()
    return { top: rect.top - box.top, bottom: rect.bottom - box.top }
  }

  const visibleKeys = (): ItemKey[] => {
    if (order.length === 0) return []
    const box = viewportBox()
    // Rows are in flow order, so their bottoms increase: binary search the first one below the top.
    let lo = 0
    let hi = order.length
    while (lo < hi) {
      const mid = (lo + hi) >> 1
      if (order[mid]!.getBoundingClientRect().bottom > box.top) hi = mid
      else lo = mid + 1
    }
    const keys: ItemKey[] = []
    for (let i = lo; i < order.length; i++) {
      const rect = order[i]!.getBoundingClientRect()
      if (rect.top >= box.bottom) break
      if (rect.bottom > box.top) keys.push(keyOf(order[i]!)!)
    }
    return keys
  }

  const activity = (): Activity => ({
    visible: doc.visibilityState !== "hidden",
    active: typeof doc.hasFocus === "function" ? doc.hasFocus() : true,
  })

  // -------------------------------------------------------------------------
  // Events

  const supportsScrollEnd = "onscrollend" in container
  let cancelScrollEndFallback: (() => void) | undefined
  let pointerDown = false
  let pointerInputSent = false
  let touchY: number | undefined
  let touchDirection: "up" | "down" | undefined

  const onWheel = (event: WheelEvent) => {
    // Ctrl with a wheel is pinch zoom on trackpads, not scrolling.
    if (event.ctrlKey || event.deltaY === 0) return
    emit({ kind: "input", source: "wheel", direction: event.deltaY < 0 ? "up" : "down" })
  }

  const onTouchStart = (event: TouchEvent) => {
    touchY = event.touches[0]?.clientY
    touchDirection = undefined
    emit({ kind: "input", source: "touch", held: true })
  }

  const onTouchMove = (event: TouchEvent) => {
    const y = event.touches[0]?.clientY
    if (y === undefined || touchY === undefined) return
    const dy = y - touchY
    touchY = y
    if (dy === 0) return
    // A finger moving down drags the content down: towards older rows.
    const direction = dy > 0 ? "up" : "down"
    if (direction === touchDirection) return
    touchDirection = direction
    emit({ kind: "input", source: "touch", direction, held: true })
  }

  const onTouchEnd = (event: TouchEvent) => {
    if (event.touches.length > 0) return
    touchY = undefined
    touchDirection = undefined
    emit({ kind: "inputEnd" })
  }

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.defaultPrevented || isEditable(event.target)) return
    // Only unmodified scroll keys scroll the list. With Alt, Ctrl or Cmd they
    // are shortcuts (Alt+Up is "previous chat"); with Shift they extend a
    // selection. Shift+Space is the one modified scroll key (page up).
    if (event.altKey || event.ctrlKey || event.metaKey) return
    let direction: "up" | "down" | undefined
    if (event.key === " ") direction = event.shiftKey ? "up" : "down"
    else if (event.shiftKey) return
    else if (UP_KEYS.has(event.key)) direction = "up"
    else if (DOWN_KEYS.has(event.key)) direction = "down"
    if (!direction) return
    emit({ kind: "input", source: "key", direction })
  }

  const onPointerUp = () => {
    view?.removeEventListener("pointerup", onPointerUp, true)
    view?.removeEventListener("pointercancel", onPointerUp, true)
    pointerDown = false
    if (pointerInputSent) {
      pointerInputSent = false
      emit({ kind: "inputEnd" })
    }
  }

  const onPointerDown = (event: PointerEvent) => {
    if (event.button !== 0 || event.pointerType === "touch") return
    pointerDown = true
    pointerInputSent = false
    view?.addEventListener("pointerup", onPointerUp, true)
    view?.addEventListener("pointercancel", onPointerUp, true)
    // A press in a classic scrollbar's gutter is scrollbar input at once.
    if (event.target === container && container.clientWidth > 0 && event.offsetX >= container.clientWidth) {
      pointerInputSent = true
      emit({ kind: "input", source: "scrollbar", held: true })
    }
  }

  const onScroll = () => {
    if (pointerDown && !pointerInputSent) {
      pointerInputSent = true
      emit({ kind: "input", source: "scrollbar", held: true })
    }
    emit({ kind: "scroll" })
    if (!supportsScrollEnd) {
      cancelScrollEndFallback?.()
      cancelScrollEndFallback = clock.setTimeout(() => {
        cancelScrollEndFallback = undefined
        emit({ kind: "scrollEnd" })
      }, SCROLL_IDLE_MS)
    }
  }

  const onScrollEnd = () => emit({ kind: "scrollEnd" })
  const onActivity = () => emit({ kind: "activity", ...activity() })

  const passive = { passive: true } as const
  container.addEventListener("wheel", onWheel, passive)
  container.addEventListener("touchstart", onTouchStart, passive)
  container.addEventListener("touchmove", onTouchMove, passive)
  container.addEventListener("touchend", onTouchEnd, passive)
  container.addEventListener("touchcancel", onTouchEnd, passive)
  container.addEventListener("keydown", onKeyDown)
  container.addEventListener("pointerdown", onPointerDown)
  container.addEventListener("scroll", onScroll, passive)
  if (supportsScrollEnd) container.addEventListener("scrollend", onScrollEnd, passive)
  doc.addEventListener("visibilitychange", onActivity)
  view?.addEventListener("focus", onActivity)
  view?.addEventListener("blur", onActivity)

  return {
    viewportHeight: () => container.clientHeight,
    contentHeight: () => container.scrollHeight,
    scrollOffset: () => container.scrollTop,
    insets,
    rowKeys: () => order.map((element) => keyOf(element)!),
    rowRect,
    visibleKeys,
    activity,
    setScrollOffset: (offset) => {
      container.scrollTop = offset
    },
    animateScroll: (to, animation, done) =>
      animateOffset(
        frames,
        clock,
        () => container.scrollTop,
        (offset) => {
          container.scrollTop = offset
        },
        to,
        animation,
        done,
      ),
    subscribe: (listener) => {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    notifyInsets: () => emit({ kind: "viewport" }),
    dispose: () => {
      mutationObserver.disconnect()
      resizeObserver?.disconnect()
      cancelScrollEndFallback?.()
      container.removeEventListener("wheel", onWheel)
      container.removeEventListener("touchstart", onTouchStart)
      container.removeEventListener("touchmove", onTouchMove)
      container.removeEventListener("touchend", onTouchEnd)
      container.removeEventListener("touchcancel", onTouchEnd)
      container.removeEventListener("keydown", onKeyDown)
      container.removeEventListener("pointerdown", onPointerDown)
      container.removeEventListener("scroll", onScroll)
      container.removeEventListener("scrollend", onScrollEnd)
      doc.removeEventListener("visibilitychange", onActivity)
      view?.removeEventListener("focus", onActivity)
      view?.removeEventListener("blur", onActivity)
      view?.removeEventListener("pointerup", onPointerUp, true)
      view?.removeEventListener("pointercancel", onPointerUp, true)
      listeners.clear()
    },
  }
}
