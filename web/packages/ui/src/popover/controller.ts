/**
 * Popover: non-modal content anchored to a trigger (APG "Disclosure" plus a
 * dialog role for rich content). Opens on click, closes on Escape, outside
 * press, focus leaving, or the trigger. Focus moves in on open and back to
 * the trigger on close. Lives in the top layer as `popover="manual"`.
 */

import { effect, type ReadSignal, type Signal, signal, untracked } from "@inline/reactive"
import { type DismissLayer, type DismissReason, pushDismissLayer } from "../foundations/dismiss"
import { type Dispose, disposeAll, listen, type Rect, setAttr, setBoolAttr } from "../foundations/dom"
import { activateFocusScope, type FocusScope, type FocusTarget } from "../foundations/focus"
import { createId } from "../foundations/id"
import { hideLayer, LAYER_ATTRIBUTE, showLayer, trackLayer } from "../foundations/layer"
import type { Placement } from "../foundations/position"
import type { Part } from "../foundations/parts"

export type PopoverOptions = {
  placement?: Placement
  offset?: number
  /** Size of the arrow, when the view draws one. Its offset lands in `--ui-arrow-x/y`. */
  arrowSize?: number
  /** Content role. Default "dialog". */
  role?: "dialog" | "region" | "group"
  /** Accessible name when the content has no heading wired with `aria-labelledby`. */
  label?: string
  /** Where focus goes on open. Default: first tabbable, else the content. "none" keeps focus on the trigger. */
  initialFocus?: FocusTarget | "none"
  /** Close when focus leaves the trigger and content. Default true. */
  closeOnFocusOutside?: boolean
  /** Anchor to something other than the trigger. */
  anchor?: () => Element | Rect | null
  onOpenChange?: (open: boolean) => void
}

export class PopoverController {
  readonly id = createId("popover")
  readonly #options: PopoverOptions
  readonly #isOpen: Signal<boolean> = signal(false)
  #trigger: HTMLElement | null = null
  #content: HTMLElement | null = null
  #layer: DismissLayer | null = null
  #scope: FocusScope | null = null
  #restoreTarget: HTMLElement | null = null

  readonly isOpen: ReadSignal<boolean> = this.#isOpen

  constructor(options: PopoverOptions = {}) {
    this.#options = options
  }

  open(): void {
    if (this.#isOpen.peek()) return
    const doc = this.#trigger?.ownerDocument ?? this.#content?.ownerDocument ?? document
    const active = doc.activeElement
    this.#restoreTarget = active instanceof HTMLElement && active !== doc.body ? active : this.#trigger
    this.#layer = pushDismissLayer(doc, {
      elements: () => [this.#content],
      ignore: () => [this.#trigger],
      focusOutside: this.#options.closeOnFocusOutside ?? true,
      onDismiss: (reason) => this.#dismiss(reason),
    })
    this.#isOpen.set(true)
    this.#options.onOpenChange?.(true)
  }

  close(options: { restoreFocus?: boolean } = {}): void {
    if (!this.#isOpen.peek()) return
    this.#layer?.dispose()
    this.#layer = null
    const scope = this.#scope
    this.#scope = null
    this.#isOpen.set(false)
    scope?.deactivate({ restore: options.restoreFocus ?? true })
    if (!scope && (options.restoreFocus ?? true) && this.#restoreTarget?.isConnected) {
      const active = this.#restoreTarget.ownerDocument.activeElement
      if (!active || active === this.#restoreTarget.ownerDocument.body) this.#restoreTarget.focus({ preventScroll: true })
    }
    this.#options.onOpenChange?.(false)
  }

  toggle(): void {
    if (this.#isOpen.peek()) this.close()
    else this.open()
  }

  #dismiss(reason: DismissReason): void {
    this.close({ restoreFocus: reason !== "focus-outside" })
  }

  readonly trigger: Part = {
    attach: (element) => {
      this.#trigger = element
      setAttr(element, "aria-haspopup", this.#options.role === "dialog" || !this.#options.role ? "dialog" : null)
      const disposers: Dispose[] = [
        effect(() => {
          const open = this.#isOpen.get()
          setBoolAttr(element, "aria-expanded", open)
          setAttr(element, "aria-controls", open ? this.id : null)
          setAttr(element, "data-state", open ? "open" : "closed")
        }),
        listen(element, "click", () => this.toggle()),
      ]
      return () => {
        disposeAll(disposers)
        if (this.#trigger === element) this.#trigger = null
      }
    },
  }

  readonly content: Part = {
    attach: (element) => {
      this.#content = element
      element.id = this.id
      element.setAttribute("role", this.#options.role ?? "dialog")
      element.setAttribute(LAYER_ATTRIBUTE, "")
      if (!element.hasAttribute("tabindex")) element.tabIndex = -1
      if (!element.hasAttribute("popover")) element.setAttribute("popover", "manual")
      if (this.#options.label) element.setAttribute("aria-label", this.#options.label)
      let stopTracking: Dispose | null = null
      const disposers: Dispose[] = [
        effect(() => {
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
              anchor: () => this.#options.anchor?.() ?? this.#trigger,
              placement: this.#options.placement ?? "bottom",
              offset: this.#options.offset ?? 8,
              padding: 8,
              arrow: this.#options.arrowSize ? { size: this.#options.arrowSize, padding: 12 } : undefined,
            })
            this.#scope?.deactivate({ restore: false })
            this.#scope = activateFocusScope(element, {
              initialFocus: this.#options.initialFocus,
              finalFocus: () => this.#restoreTarget,
            })
          })
        }),
      ]
      return () => {
        stopTracking?.()
        disposeAll(disposers)
        hideLayer(element)
        if (this.#content === element) this.#content = null
      }
    },
  }

  dispose(): void {
    this.close({ restoreFocus: false })
  }
}
