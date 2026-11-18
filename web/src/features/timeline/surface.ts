/**
 * The timeline's DOM surface: what `TimelineView` binds to, framework-free.
 *
 * It owns no scroll logic. It creates the DOM host for the scroll container
 * the view hands it and attaches the controller to it, derives the
 * per-row signals the view renders from (so a change to one row renders that
 * row only and the list reads keys), times the highlight flash, carries the
 * overlay insets, and gives the app a `focus()` handle.
 *
 * Nothing here writes the scroll offset or measures layout: the controller
 * does both, through the host.
 */

import { computed, effect, sameKeys, signal, type ReadSignal } from "@inline/reactive"
import {
  browserClock,
  createDomHost,
  type Clock,
  type DomHost,
  type FrameSource,
  type Highlight,
  type Insets,
  type ItemKey,
  type TimelineController,
  type TimelineItem,
  type TimelineWindow,
} from "@inline/timeline"
import { isEmpty, newerEdge, olderEdge, type EdgeInput, type NewerEdge, type OlderEdge } from "./chrome"

/** Marks the element whose direct children are the rows (the DOM host's `content`). */
export const CONTENT_ATTRIBUTE = "data-timeline-content"

/**
 * One highlight flash, start to end. Mac `MessageTableRow.highlight`: 0.2 s
 * fade in, held 0.4 s, 0.25 s fade out. The view's keyframes use the same
 * split (`TimelineView.tsx`, `flashIn`).
 */
export const FLASH_MS = 850

/** CSS custom properties the surface sets from code for the overlay insets (CSSOM; allowed by the CSP). */
export const INSET_TOP_VAR = "--timeline-inset-top"
export const INSET_BOTTOM_VAR = "--timeline-inset-bottom"

export type TimelineSurfaceOptions = {
  controller: TimelineController
  /**
   * The core's window, the same value given to `controller.setItems`. Drives
   * the "loading older/newer" placeholders and the empty state. Optional:
   * without it the placeholders follow the rendered range only.
   */
  window?: ReadSignal<TimelineWindow>
  /** Overlays covering the list at start (a translucent header, an overlaid composer). */
  insets?: Insets
  /** For the DOM host and the flash timer; the browser's by default. */
  clock?: Clock
  frames?: FrameSource
}

export interface TimelineSurface {
  readonly controller: TimelineController
  /** Keys of the rendered items, in order. Equal key lists keep their identity, so the list renders only on membership changes. */
  readonly keys: ReadSignal<readonly ItemKey[]>
  /** The rendered item with this key. Notifies only when that item changes. */
  item(key: ItemKey): ReadSignal<TimelineItem | undefined>
  /** The flash sequence number while this row is flashing, else 0. */
  flash(key: ItemKey): ReadSignal<number>
  readonly olderEdge: ReadSignal<OlderEdge>
  readonly newerEdge: ReadSignal<NewerEdge>
  readonly empty: ReadSignal<boolean>
  /** Part for the view's root element (positions the chrome by the insets). */
  readonly root: (element: HTMLElement) => () => void
  /** Part for the scroll container. Creates the DOM host and attaches the controller. */
  readonly container: (element: HTMLElement) => () => void
  /** The attached scroll container, or null. For labs and tests; the app uses `focus()`. */
  element(): HTMLElement | null
  /** Move keyboard focus to the list so Page Up/Down, Home/End, arrows and Space scroll it. True when focus landed. */
  focus(): boolean
  insets(): Insets
  /** The overlays changed (the composer grew, a header appeared). */
  setInsets(insets: Insets): void
  dispose(): void
}

const sameInsets = (a: Insets, b: Insets) => a.top === b.top && a.bottom === b.bottom

export const createTimelineSurface = (options: TimelineSurfaceOptions): TimelineSurface => {
  const { controller } = options
  const clock = options.clock ?? browserClock
  let currentInsets: Insets = options.insets ?? { top: 0, bottom: 0 }
  let disposed = false

  // ---------------------------------------------------------------------------
  // Per-row signals

  const keys = computed(() => controller.rendered.get().map((item) => item.key), { equals: sameKeys })

  const byKey = computed(() => {
    const map = new Map<ItemKey, TimelineItem>()
    for (const item of controller.rendered.get()) map.set(item.key, item)
    return map
  })

  const itemSignals = new Map<ItemKey, ReadSignal<TimelineItem | undefined>>()
  const flashSignals = new Map<ItemKey, ReadSignal<number>>()

  /** Forget signals of rows that left the rendered range once they outnumber the rendered rows. */
  const prune = () => {
    const live = byKey.peek()
    if (itemSignals.size <= live.size * 2 + 64) return
    for (const key of itemSignals.keys()) if (!live.has(key)) itemSignals.delete(key)
    for (const key of flashSignals.keys()) if (!live.has(key)) flashSignals.delete(key)
  }

  const item = (key: ItemKey) => {
    let cached = itemSignals.get(key)
    if (!cached) {
      // A row leaving the range keeps its last item until the list drops it, so it never renders empty.
      let last: TimelineItem | undefined
      cached = computed(() => {
        const found = byKey.get().get(key)
        if (found) last = found
        return last
      })
      itemSignals.set(key, cached)
      prune()
    }
    return cached
  }

  // ---------------------------------------------------------------------------
  // Highlight flash

  /**
   * The flash in progress. Cleared after `FLASH_MS`, so a row re-entering the
   * window later does not flash again. A highlight for a row that is not in
   * the rendered range yet stays pending, and its time starts when the row
   * renders (the controller highlights on landing, when the row is already
   * rendered; this guards any other order).
   */
  const flashing = signal<Highlight | null>(null)
  let cancelFlash: (() => void) | undefined
  let seenSeq = controller.highlight.peek()?.seq
  const stopFlashWatch = effect(() => {
    const highlight = controller.highlight.get()
    if (!highlight) {
      cancelFlash?.()
      cancelFlash = undefined
      flashing.set(null)
      return
    }
    if (highlight.seq === seenSeq) return
    // Pending: tracked, so this re-runs when the rendered rows change, until the row is there.
    if (!byKey.get().has(highlight.key)) return
    seenSeq = highlight.seq
    cancelFlash?.()
    flashing.set(highlight)
    cancelFlash = clock.setTimeout(() => {
      cancelFlash = undefined
      flashing.set(null)
    }, FLASH_MS)
  })

  const flash = (key: ItemKey) => {
    let cached = flashSignals.get(key)
    if (!cached) {
      cached = computed(() => {
        const current = flashing.get()
        return current !== null && current.key === key ? current.seq : 0
      })
      flashSignals.set(key, cached)
    }
    return cached
  }

  // ---------------------------------------------------------------------------
  // Chrome

  const edgeInput = (): EdgeInput => ({
    window: options.window?.get(),
    range: controller.range.get(),
    length: controller.items.get().length,
    hidden: controller.hidden.get(),
  })

  // ---------------------------------------------------------------------------
  // DOM

  let rootElement: HTMLElement | null = null
  let containerElement: HTMLElement | null = null
  let domHost: DomHost | null = null

  const writeInsetVars = (element: HTMLElement) => {
    element.style.setProperty(INSET_TOP_VAR, `${currentInsets.top}px`)
    element.style.setProperty(INSET_BOTTOM_VAR, `${currentInsets.bottom}px`)
  }

  const root = (element: HTMLElement) => {
    rootElement = element
    writeInsetVars(element)
    return () => {
      if (rootElement === element) rootElement = null
    }
  }

  const container = (element: HTMLElement) => {
    // The content's bottom padding follows the inset, so it must be right before the controller places anything.
    writeInsetVars(element)
    const content = element.querySelector<HTMLElement>(`:scope > [${CONTENT_ATTRIBUTE}]`) ?? element
    const host = createDomHost(element, {
      content,
      insets: () => currentInsets,
      clock,
      ...(options.frames ? { frames: options.frames } : {}),
    })
    containerElement = element
    domHost = host
    controller.attach(host)
    return () => {
      if (domHost === host) {
        controller.detach()
        domHost = null
      }
      host.dispose()
      if (containerElement === element) containerElement = null
    }
  }

  const setInsets = (next: Insets) => {
    if (sameInsets(next, currentInsets)) return
    currentInsets = { top: next.top, bottom: next.bottom }
    // Style first, so the controller reads the new content height when it reconciles.
    if (rootElement) writeInsetVars(rootElement)
    if (containerElement) writeInsetVars(containerElement)
    domHost?.notifyInsets()
  }

  const focus = () => {
    const element = containerElement
    if (!element) return false
    element.focus({ preventScroll: true })
    return element.ownerDocument.activeElement === element
  }

  return {
    controller,
    keys,
    item,
    flash,
    olderEdge: computed(() => olderEdge(edgeInput())),
    newerEdge: computed(() => newerEdge(edgeInput())),
    empty: computed(() => isEmpty(edgeInput())),
    root,
    container,
    element: () => containerElement,
    focus,
    insets: () => currentInsets,
    setInsets,
    dispose: () => {
      if (disposed) return
      disposed = true
      stopFlashWatch()
      cancelFlash?.()
      cancelFlash = undefined
    },
  }
}
