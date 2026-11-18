/**
 * Toast queue: short, non-blocking notifications. A few show at once, the
 * rest wait. Each visible toast dismisses itself after its duration; hovering
 * or focusing the region pauses every timer, as does the window losing focus.
 * The region is a `popover="manual"` landmark so it sits in the top layer.
 *
 * Placement comes from the app: attach `container` to the element whose
 * inline-end, block-end corner should hold the toasts (the message list above
 * the composer, say), and the region sits in that corner, `offset` in from
 * both edges, never wider than the container. Without a container it uses
 * the window's corner. The region writes `--ui-toast-inset-inline-end`,
 * `--ui-toast-inset-block-end` and `--ui-toast-max-inline-size` on itself;
 * the view's styles read them.
 */

import { batch, computed, effect, type ReadSignal, type Signal, signal, untracked } from "@inline/reactive"
import { type Clock, systemClock, type TimerHandle } from "../foundations/clock"
import { contains, type Direction, directionOf, type Dispose, disposeAll, listen, type Rect, rectOf, viewportRect } from "../foundations/dom"
import { createId } from "../foundations/id"
import { hideLayer, raiseLayer, showLayer } from "../foundations/layer"
import type { Part } from "../foundations/parts"

export type ToastTone = "neutral" | "success" | "warning" | "error"

export type ToastInput = {
  /** Reusing an ID replaces that toast in place (e.g. "Uploading…" then "Uploaded"). */
  id?: string
  title: string
  description?: string
  tone?: ToastTone
  /** Milliseconds; Infinity keeps it until dismissed. Default from the queue. */
  duration?: number
  action?: { label: string; onAction: () => void }
}

export type Toast = Required<Pick<ToastInput, "id" | "title" | "tone" | "duration">> &
  Pick<ToastInput, "description" | "action">

export type ToastQueueOptions = {
  clock?: Clock
  /** Toasts visible at once. Default 3. */
  max?: number
  /** Default duration. 5000ms. */
  duration?: number
  label?: string
  /** Distance from the container's (or window's) inline-end and block-end edges, in px. Default 16 and 16. */
  offset?: ToastOffset
}

export type ToastOffset = { readonly inline?: number; readonly block?: number }

/** Where the region sits: insets from the viewport's inline-end and block-end edges, and its widest. */
export type ToastPlacement = {
  readonly insetInlineEnd: number
  readonly insetBlockEnd: number
  /** Undefined without a container: the view's own bound (the window less a gutter) applies. */
  readonly maxInlineSize?: number
}

export const DEFAULT_TOAST_OFFSET = { inline: 16, block: 16 } as const

/**
 * The region's placement for a container's rectangle in the viewport (null:
 * the window). Inline-end is the right edge in left-to-right, the left edge in
 * right-to-left; block-end is the bottom. Pure.
 */
export const toastPlacement = (
  container: Rect | null,
  viewport: { readonly width: number; readonly height: number },
  dir: Direction,
  offset: ToastOffset = {},
): ToastPlacement => {
  const inline = offset.inline ?? DEFAULT_TOAST_OFFSET.inline
  const block = offset.block ?? DEFAULT_TOAST_OFFSET.block
  if (!container) return { insetInlineEnd: inline, insetBlockEnd: block }
  const fromEnd = dir === "rtl" ? container.x : viewport.width - (container.x + container.width)
  const fromBottom = viewport.height - (container.y + container.height)
  return {
    insetInlineEnd: Math.max(0, Math.round(fromEnd + inline)),
    insetBlockEnd: Math.max(0, Math.round(fromBottom + block)),
    maxInlineSize: Math.max(0, Math.round(container.width - inline * 2)),
  }
}

type Timing = { remaining: number; startedAt: number; handle: TimerHandle | null }

export class ToastQueue {
  readonly id = createId("toasts")
  readonly #clock: Clock
  readonly #options: ToastQueueOptions
  readonly #toasts: Signal<readonly Toast[]> = signal<readonly Toast[]>([])
  readonly #paused: Signal<boolean> = signal(false)
  readonly #timings = new Map<string, Timing>()
  /** Attached containers, newest last: the newest one places the region. */
  readonly #containers: Signal<readonly HTMLElement[]> = signal<readonly HTMLElement[]>([])
  #regionElement: HTMLElement | null = null

  readonly toasts: ReadSignal<readonly Toast[]> = this.#toasts
  readonly visible: ReadSignal<readonly Toast[]>
  readonly paused: ReadSignal<boolean> = this.#paused

  constructor(options: ToastQueueOptions = {}) {
    this.#options = options
    this.#clock = options.clock ?? systemClock
    const max = options.max ?? 3
    this.visible = computed(() => this.#toasts.get().slice(0, max))
  }

  show(input: ToastInput): string {
    const toast: Toast = {
      id: input.id ?? createId("toast"),
      title: input.title,
      description: input.description,
      tone: input.tone ?? "neutral",
      duration: input.duration ?? this.#options.duration ?? 5000,
      action: input.action,
    }
    const existing = this.#toasts.peek().findIndex((candidate) => candidate.id === toast.id)
    if (existing >= 0) {
      this.#toasts.update((list) => list.map((candidate, index) => (index === existing ? toast : candidate)))
      this.#clearTiming(toast.id)
    } else {
      this.#toasts.update((list) => [...list, toast])
    }
    this.#syncTimers()
    return toast.id
  }

  dismiss(id: string): void {
    this.#clearTiming(id)
    this.#toasts.update((list) => list.filter((toast) => toast.id !== id))
    this.#syncTimers()
  }

  clear(): void {
    // Deleting the current key while iterating a Map is safe.
    for (const id of this.#timings.keys()) this.#clearTiming(id)
    this.#toasts.set([])
  }

  pause(): void {
    if (this.#paused.peek()) return
    this.#paused.set(true)
    const now = this.#clock.now()
    for (const timing of this.#timings.values()) {
      if (timing.handle === null) continue
      this.#clock.clearTimeout(timing.handle)
      timing.handle = null
      timing.remaining = Math.max(0, timing.remaining - (now - timing.startedAt))
    }
  }

  resume(): void {
    if (!this.#paused.peek()) return
    this.#paused.set(false)
    this.#syncTimers()
  }

  #clearTiming(id: string): void {
    const timing = this.#timings.get(id)
    if (timing) this.#clock.clearTimeout(timing.handle)
    this.#timings.delete(id)
  }

  /** Start timers for visible toasts that have none; resume paused ones. */
  #syncTimers(): void {
    if (this.#paused.peek()) return
    for (const toast of untracked(() => this.visible.get())) {
      if (!Number.isFinite(toast.duration)) continue
      let timing = this.#timings.get(toast.id)
      if (!timing) {
        timing = { remaining: toast.duration, startedAt: 0, handle: null }
        this.#timings.set(toast.id, timing)
      }
      if (timing.handle !== null) continue
      timing.startedAt = this.#clock.now()
      timing.handle = this.#clock.setTimeout(() => this.dismiss(toast.id), timing.remaining)
    }
  }

  /**
   * The element whose inline-end, block-end corner holds the toasts. Attach
   * it to a container the app lays out (`useElement(queue.container)`); the
   * newest attached container wins, and detaching falls back to the one
   * before, then to the window.
   */
  readonly container: Part = {
    attach: (element) => {
      this.#containers.update((list) => [...list.filter((candidate) => candidate !== element), element])
      const view = element.ownerDocument.defaultView
      let observer: ResizeObserver | null = null
      if (view && "ResizeObserver" in view) {
        observer = new view.ResizeObserver(() => this.reposition())
        observer.observe(element)
      }
      return () => {
        observer?.disconnect()
        this.#containers.update((list) => list.filter((candidate) => candidate !== element))
      }
    },
  }

  /** The placement for the current container, measured now. */
  placement(): ToastPlacement {
    const containers = this.#containers.peek()
    const container = containers[containers.length - 1] ?? null
    const doc = container?.ownerDocument ?? this.#regionElement?.ownerDocument ?? (typeof document === "undefined" ? null : document)
    if (!doc) return toastPlacement(null, { width: 0, height: 0 }, "ltr", this.#options.offset)
    const dir = directionOf(container ?? this.#regionElement ?? doc.documentElement)
    return toastPlacement(container ? rectOf(container) : null, viewportRect(doc), dir, this.#options.offset)
  }

  /** Measure the container again and move the region (the view calls this when layout changes in ways it cannot observe). */
  reposition(): void {
    const element = this.#regionElement
    if (!element) return
    const placement = this.placement()
    element.style.setProperty("--ui-toast-inset-inline-end", `${placement.insetInlineEnd}px`)
    element.style.setProperty("--ui-toast-inset-block-end", `${placement.insetBlockEnd}px`)
    if (placement.maxInlineSize === undefined) element.style.removeProperty("--ui-toast-max-inline-size")
    else element.style.setProperty("--ui-toast-max-inline-size", `${placement.maxInlineSize}px`)
  }

  /** The landmark that holds the toasts. */
  readonly region: Part = {
    attach: (element) => {
      this.#regionElement = element
      element.id = this.id
      element.setAttribute("role", "region")
      element.setAttribute("aria-label", this.#options.label ?? "Notifications")
      if (!element.hasAttribute("popover")) element.setAttribute("popover", "manual")
      const view = element.ownerDocument.defaultView
      const disposers: Dispose[] = [
        effect(() => {
          const any = this.#toasts.get().length > 0
          this.#containers.get()
          untracked(() => {
            if (any) {
              this.reposition()
              showLayer(element)
            } else {
              hideLayer(element)
            }
          })
        }),
        listen(element, "pointerenter", () => this.pause()),
        listen(element, "pointerleave", () => {
          if (!contains(element, element.ownerDocument.activeElement)) this.resume()
        }),
        listen(element, "focusin", () => this.pause()),
        listen(element, "focusout", (event: FocusEvent) => {
          if (!contains(element, event.relatedTarget)) this.resume()
        }),
      ]
      if (view) {
        disposers.push(
          listen(view, "blur", () => this.pause()),
          listen(view, "focus", () => this.resume()),
          listen(view, "resize", () => this.reposition()),
        )
      }
      return () => {
        disposeAll(disposers)
        hideLayer(element)
        if (this.#regionElement === element) this.#regionElement = null
      }
    },
  }

  /** Bring the region above layers opened after it (call after opening a modal dialog). */
  raise(element: HTMLElement): void {
    raiseLayer(element)
  }

  dispose(): void {
    batch(() => this.clear())
  }
}
