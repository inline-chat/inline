/**
 * SplitView with resizable panes (APG "Window Splitter"). One pane is
 * flexible and takes the remaining space; the others have pixel sizes with
 * minimum and maximum, and may collapse. Separators resize with the pointer
 * or the keyboard. Sizes persist as plain data (`state()` and `initial`).
 *
 * Like the Mac sidebar: dragging a collapsible pane below half its minimum
 * collapses it, dragging back past that point restores it at the minimum.
 */

import { batch, computed, effect, type ReadSignal, type Signal, signal } from "@inline/reactive"
import { type Dispose, directionOf, disposeAll, type KeyInput, listen, setAttr } from "../foundations/dom"
import { createId } from "../foundations/id"
import type { Part } from "../foundations/parts"

export type PaneSpec = {
  id: string
  /** Default size in pixels. Ignored for the flexible pane. */
  size?: number
  minSize?: number
  maxSize?: number
  collapsible?: boolean
  /** Takes the remaining space. Exactly one pane should be flexible. */
  flex?: boolean
  /** Accessible name for the separator that resizes this pane. */
  label?: string
}

export type SplitViewState = { sizes: Record<string, number>; collapsed: string[] }

export type SplitViewOptions = {
  panes: readonly PaneSpec[]
  /** "horizontal" lays panes side by side (vertical separators). Default "horizontal". */
  orientation?: "horizontal" | "vertical"
  initial?: Partial<SplitViewState>
  /** Called with the new state after a resize or collapse finishes. Persist it as is. */
  onChange?: (state: SplitViewState) => void
  /** Keyboard step in pixels; Shift multiplies it by 5. Default 10. */
  step?: number
}

type PaneState = { spec: PaneSpec; size: Signal<number>; collapsed: Signal<boolean> }

export class SplitViewController {
  readonly id = createId("split")
  readonly orientation: "horizontal" | "vertical"
  readonly #options: SplitViewOptions
  readonly #panes: PaneState[]
  readonly #container: Signal<number> = signal(0)
  readonly #separatorParts = new Map<number, Part>()
  readonly #paneParts = new Map<string, Part>()
  readonly #sizeSignals = new Map<string, ReadSignal<number>>()
  #root: HTMLElement | null = null

  constructor(options: SplitViewOptions) {
    this.#options = options
    this.orientation = options.orientation ?? "horizontal"
    const collapsed = new Set(options.initial?.collapsed ?? [])
    this.#panes = options.panes.map((spec) => {
      const stored = options.initial?.sizes?.[spec.id]
      const size = this.#clamp(spec, typeof stored === "number" && Number.isFinite(stored) ? stored : (spec.size ?? 200))
      return { spec, size: signal(size), collapsed: signal(!!spec.collapsible && collapsed.has(spec.id)) }
    })
  }

  #pane(id: string): PaneState | undefined {
    return this.#panes.find((pane) => pane.spec.id === id)
  }

  #clamp(spec: PaneSpec, size: number): number {
    return Math.round(Math.min(spec.maxSize ?? Infinity, Math.max(spec.minSize ?? 0, size)))
  }

  /** The pane's rendered size: 0 when collapsed. The flexible pane reports its remaining space. */
  size(id: string): ReadSignal<number> {
    let cached = this.#sizeSignals.get(id)
    if (!cached) {
      cached = computed(() => {
        const pane = this.#pane(id)
        if (!pane) return 0
        if (pane.spec.flex) {
          const others = this.#panes
            .filter((other) => other !== pane)
            .reduce((sum, other) => sum + (other.collapsed.get() ? 0 : other.size.get()), 0)
          return Math.max(0, this.#container.get() - others)
        }
        return pane.collapsed.get() ? 0 : pane.size.get()
      })
      this.#sizeSignals.set(id, cached)
    }
    return cached
  }

  /** True for the pane that takes the remaining space. */
  isFlexible(id: string): boolean {
    return !!this.#pane(id)?.spec.flex
  }

  isCollapsed(id: string): ReadSignal<boolean> {
    return this.#pane(id)?.collapsed ?? signal(false)
  }

  /** Plain data to persist. */
  state(): SplitViewState {
    const sizes: Record<string, number> = {}
    for (const pane of this.#panes) if (!pane.spec.flex) sizes[pane.spec.id] = pane.size.peek()
    return {
      sizes,
      collapsed: this.#panes.filter((pane) => pane.collapsed.peek()).map((pane) => pane.spec.id),
    }
  }

  /** The largest size `id` can take while the flexible pane keeps its minimum. */
  #maxFor(pane: PaneState): number {
    const container = this.#container.peek()
    const specMax = pane.spec.maxSize ?? Infinity
    if (container <= 0) return specMax
    const flex = this.#panes.find((candidate) => candidate.spec.flex)
    const others = this.#panes
      .filter((other) => other !== pane && !other.spec.flex)
      .reduce((sum, other) => sum + (other.collapsed.peek() ? 0 : other.size.peek()), 0)
    return Math.min(specMax, container - others - (flex?.spec.minSize ?? 0))
  }

  setSize(id: string, size: number, notify = true): void {
    const pane = this.#pane(id)
    if (!pane || pane.spec.flex) return
    const next = Math.round(Math.max(pane.spec.minSize ?? 0, Math.min(this.#maxFor(pane), size)))
    batch(() => {
      pane.size.set(next)
      pane.collapsed.set(false)
    })
    if (notify) this.#notify()
  }

  setCollapsed(id: string, collapsed: boolean, notify = true): void {
    const pane = this.#pane(id)
    if (!pane?.spec.collapsible || pane.collapsed.peek() === collapsed) return
    pane.collapsed.set(collapsed)
    if (notify) this.#notify()
  }

  toggleCollapsed(id: string): void {
    const pane = this.#pane(id)
    if (pane) this.setCollapsed(id, !pane.collapsed.peek())
  }

  #notify(): void {
    this.#options.onChange?.(this.state())
  }

  /** Which pane separator `index` (between pane index and index + 1) resizes, and whether it sits before it. */
  #controlled(index: number): { pane: PaneState; before: boolean } | null {
    const before = this.#panes[index]
    const after = this.#panes[index + 1]
    if (before && !before.spec.flex) return { pane: before, before: true }
    if (after && !after.spec.flex) return { pane: after, before: false }
    return null
  }

  /**
   * Move separator `index` by `delta` pixels toward the end (right in left to
   * right, down for vertical layouts), from a pane size of `from`.
   * Collapses or restores collapsible panes past half their minimum.
   */
  #resizeBy(index: number, from: number, delta: number, notify: boolean): void {
    const target = this.#controlled(index)
    if (!target) return
    const { pane, before } = target
    const raw = from + (before ? delta : -delta)
    const min = pane.spec.minSize ?? 0
    if (pane.spec.collapsible && raw < min / 2) {
      this.setCollapsed(pane.spec.id, true, notify)
      return
    }
    this.setSize(pane.spec.id, raw, notify)
  }

  handleSeparatorKey(index: number, event: KeyInput): boolean {
    const target = this.#controlled(index)
    if (!target) return false
    const { pane, before } = target
    const horizontal = this.orientation === "horizontal"
    const rtl = horizontal && directionOf(this.#root) === "rtl"
    const step = (this.#options.step ?? 10) * (event.shiftKey ? 5 : 1)
    const forward = horizontal ? (rtl ? "ArrowLeft" : "ArrowRight") : "ArrowDown"
    const backward = horizontal ? (rtl ? "ArrowRight" : "ArrowLeft") : "ArrowUp"
    const current = pane.collapsed.peek() ? 0 : pane.size.peek()
    const id = pane.spec.id
    switch (event.key) {
      case forward:
      case backward: {
        const delta = event.key === forward ? step : -step
        if (pane.collapsed.peek()) {
          if ((before ? delta : -delta) > 0) this.setCollapsed(id, false)
          return true
        }
        const next = current + (before ? delta : -delta)
        if (pane.spec.collapsible && next < (pane.spec.minSize ?? 0)) this.setCollapsed(id, true)
        else this.setSize(id, next)
        return true
      }
      case "Home":
        if (pane.spec.collapsible) this.setCollapsed(id, true)
        else this.setSize(id, pane.spec.minSize ?? 0)
        return true
      case "End":
        this.setSize(id, this.#maxFor(pane))
        return true
      case "Enter":
        this.toggleCollapsed(id)
        return true
    }
    return false
  }

  /** The element that holds the panes; its size bounds the flexible pane. */
  readonly root: Part = {
    attach: (element) => {
      this.#root = element
      element.setAttribute("data-orientation", this.orientation)
      const measure = () => {
        const rect = element.getBoundingClientRect()
        this.#container.set(this.orientation === "horizontal" ? rect.width : rect.height)
      }
      measure()
      const view = element.ownerDocument.defaultView
      let observer: ResizeObserver | null = null
      if (view && "ResizeObserver" in view) {
        observer = new view.ResizeObserver(measure)
        observer.observe(element)
      }
      return () => {
        observer?.disconnect()
        if (this.#root === element) this.#root = null
      }
    },
  }

  /** Set the container size directly (tests, or a parent that already measures). */
  setContainerSize(size: number): void {
    this.#container.set(size)
  }

  pane(id: string): Part {
    let part = this.#paneParts.get(id)
    if (!part) {
      part = {
        attach: (element) => {
          element.id = `${this.id}-${id}`
          return effect(() => setAttr(element, "data-collapsed", this.#pane(id)?.collapsed.get() ?? false))
        },
      }
      this.#paneParts.set(id, part)
    }
    return part
  }

  /** The separator between pane `index` and pane `index + 1`. */
  separator(index: number): Part {
    let part = this.#separatorParts.get(index)
    if (!part) {
      part = { attach: (element) => this.#attachSeparator(index, element) }
      this.#separatorParts.set(index, part)
    }
    return part
  }

  #attachSeparator(index: number, element: HTMLElement): Dispose {
    const target = this.#controlled(index)
    element.setAttribute("role", "separator")
    element.setAttribute("aria-orientation", this.orientation === "horizontal" ? "vertical" : "horizontal")
    element.tabIndex = 0
    if (target) {
      element.setAttribute("aria-controls", `${this.id}-${target.pane.spec.id}`)
      setAttr(element, "aria-label", target.pane.spec.label)
    }
    let drag: { pointerId: number; start: number; from: number; rtl: boolean } | null = null
    const coordinate = (event: PointerEvent) => (this.orientation === "horizontal" ? event.clientX : event.clientY)
    const disposers: Dispose[] = [
      effect(() => {
        if (!target) return
        const { pane } = target
        const size = pane.collapsed.get() ? 0 : pane.size.get()
        this.#container.get()
        element.setAttribute("aria-valuenow", String(size))
        element.setAttribute("aria-valuemin", String(pane.spec.collapsible ? 0 : (pane.spec.minSize ?? 0)))
        const max = this.#maxFor(pane)
        setAttr(element, "aria-valuemax", Number.isFinite(max) ? String(Math.max(0, max)) : null)
      }),
      listen(element, "keydown", (event: KeyboardEvent) => {
        if (this.handleSeparatorKey(index, event)) event.preventDefault()
      }),
      listen(element, "pointerdown", (event: PointerEvent) => {
        if (event.button !== 0 || !target) return
        event.preventDefault()
        element.setPointerCapture?.(event.pointerId)
        drag = {
          pointerId: event.pointerId,
          start: coordinate(event),
          from: target.pane.collapsed.peek() ? 0 : target.pane.size.peek(),
          rtl: this.orientation === "horizontal" && directionOf(element) === "rtl",
        }
        element.setAttribute("data-dragging", "")
      }),
      listen(element, "pointermove", (event: PointerEvent) => {
        if (!drag || event.pointerId !== drag.pointerId) return
        const delta = coordinate(event) - drag.start
        this.#resizeBy(index, drag.from, drag.rtl ? -delta : delta, false)
      }),
      listen(element, "pointerup", (event: PointerEvent) => {
        if (!drag || event.pointerId !== drag.pointerId) return
        drag = null
        element.removeAttribute("data-dragging")
        element.releasePointerCapture?.(event.pointerId)
        this.#notify()
      }),
      listen(element, "lostpointercapture", () => {
        if (!drag) return
        drag = null
        element.removeAttribute("data-dragging")
        this.#notify()
      }),
      listen(element, "dblclick", () => {
        if (target) this.toggleCollapsed(target.pane.spec.id)
      }),
    ]
    return () => disposeAll(disposers)
  }
}
