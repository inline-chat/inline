/**
 * Tooltip (APG "Tooltip"): a short description shown on hover after a delay,
 * or at once on keyboard focus. Never on touch, never on pointer focus.
 * Escape hides it. Tooltips in one delay group open instantly while another
 * one was just showing, the way toolbar tooltips behave on macOS.
 */

import { effect, type ReadSignal, type Signal, signal, untracked } from "@inline/reactive"
import { type Clock, systemClock, Timer } from "../foundations/clock"
import { type DismissLayer, pushDismissLayer } from "../foundations/dismiss"
import { type Dispose, disposeAll, listen, setAttr } from "../foundations/dom"
import { createId } from "../foundations/id"
import { hideLayer, LAYER_ATTRIBUTE, showLayer, trackLayer } from "../foundations/layer"
import { acquireModality } from "../foundations/modality"
import type { Placement } from "../foundations/position"
import type { Part } from "../foundations/parts"

export type TooltipGroupOptions = {
  clock?: Clock
  /** Hover time before the first tooltip shows. Default 600ms. */
  delay?: number
  /** After a tooltip hides, others open without delay for this long. Default 400ms. */
  skipDelay?: number
}

/** Shared delay state: only one tooltip shows at a time, and neighbors open instantly. */
export class TooltipGroup {
  readonly clock: Clock
  readonly delay: number
  readonly skipDelay: number
  #open: TooltipController | null = null
  #lastClosedAt = -Infinity

  constructor(options: TooltipGroupOptions = {}) {
    this.clock = options.clock ?? systemClock
    this.delay = options.delay ?? 600
    this.skipDelay = options.skipDelay ?? 400
  }

  /** How long a tooltip should wait before opening now. */
  currentDelay(): number {
    if (this.#open) return 0
    return this.clock.now() - this.#lastClosedAt < this.skipDelay ? 0 : this.delay
  }

  opened(tooltip: TooltipController): void {
    if (this.#open && this.#open !== tooltip) this.#open.close()
    this.#open = tooltip
  }

  closed(tooltip: TooltipController): void {
    if (this.#open === tooltip) this.#open = null
    this.#lastClosedAt = this.clock.now()
  }
}

let defaultGroup: TooltipGroup | null = null
export const defaultTooltipGroup = (): TooltipGroup => (defaultGroup ??= new TooltipGroup())

export type TooltipOptions = {
  group?: TooltipGroup
  placement?: Placement
  offset?: number
  arrowSize?: number
}

export class TooltipController {
  readonly id = createId("tooltip")
  readonly #options: TooltipOptions
  readonly #group: TooltipGroup
  readonly #timer: Timer
  readonly #isOpen: Signal<boolean> = signal(false)
  #trigger: HTMLElement | null = null
  #layer: DismissLayer | null = null

  readonly isOpen: ReadSignal<boolean> = this.#isOpen

  constructor(options: TooltipOptions = {}) {
    this.#options = options
    this.#group = options.group ?? defaultTooltipGroup()
    this.#timer = new Timer(this.#group.clock)
  }

  /** Open after the group's current delay. */
  scheduleOpen(): void {
    if (this.#isOpen.peek()) return
    const delay = this.#group.currentDelay()
    if (delay === 0) this.open()
    else this.#timer.start(delay, () => this.open())
  }

  open(): void {
    this.#timer.stop()
    if (this.#isOpen.peek()) return
    this.#group.opened(this)
    const doc = this.#trigger?.ownerDocument ?? (typeof document === "undefined" ? null : document)
    if (doc) {
      this.#layer = pushDismissLayer(doc, {
        elements: () => [],
        outsidePress: false,
        onDismiss: () => this.close(),
      })
    }
    this.#isOpen.set(true)
  }

  close(): void {
    this.#timer.stop()
    if (!this.#isOpen.peek()) return
    this.#layer?.dispose()
    this.#layer = null
    this.#isOpen.set(false)
    this.#group.closed(this)
  }

  readonly trigger: Part = {
    attach: (element) => {
      this.#trigger = element
      setAttr(element, "aria-describedby", this.id)
      const { tracker, release } = acquireModality(element.ownerDocument)
      const disposers: Dispose[] = [
        release,
        listen(element, "pointerenter", (event: PointerEvent) => {
          if (event.pointerType === "touch") return
          this.scheduleOpen()
        }),
        listen(element, "pointerleave", () => this.close()),
        listen(element, "pointerdown", () => this.close()),
        listen(element, "focus", () => {
          if (tracker.isKeyboard()) this.open()
        }),
        listen(element, "blur", () => this.close()),
      ]
      return () => {
        disposeAll(disposers)
        this.close()
        if (this.#trigger === element) this.#trigger = null
      }
    },
  }

  readonly content: Part = {
    attach: (element) => {
      element.id = this.id
      element.setAttribute("role", "tooltip")
      element.setAttribute(LAYER_ATTRIBUTE, "")
      if (!element.hasAttribute("popover")) element.setAttribute("popover", "manual")
      let stopTracking: Dispose | null = null
      const dispose = effect(() => {
        const open = this.#isOpen.get()
        untracked(() => {
          stopTracking?.()
          stopTracking = null
          if (!open) {
            hideLayer(element)
            return
          }
          showLayer(element)
          stopTracking = trackLayer(element, {
            anchor: () => this.#trigger,
            placement: this.#options.placement ?? "top",
            offset: this.#options.offset ?? 6,
            padding: 6,
            arrow: this.#options.arrowSize ? { size: this.#options.arrowSize } : undefined,
          })
        })
      })
      return () => {
        stopTracking?.()
        dispose()
        hideLayer(element)
      }
    },
  }

  dispose(): void {
    this.close()
  }
}
