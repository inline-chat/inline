/**
 * Dialog and Sheet (APG "Dialog (Modal)"), on the platform `<dialog>`:
 * `showModal()` puts it in the top layer and makes the rest of the page inert;
 * we add a Tab trap that wraps, initial focus, focus restore, Escape and an
 * optional backdrop press through the dismiss stack, and keep the open state
 * in a signal so the view and the native element never disagree.
 *
 * A sheet is the same controller with `presentation: "sheet"`: attached to the
 * top of the window like a macOS sheet, and not closed by a backdrop press.
 */

import { effect, type ReadSignal, type Signal, signal, untracked } from "@inline/reactive"
import { type DismissLayer, pushDismissLayer } from "../foundations/dismiss"
import { type Dispose, disposeAll, listen, setAttr } from "../foundations/dom"
import { activateFocusScope, type FocusScope, type FocusTarget } from "../foundations/focus"
import { createId } from "../foundations/id"
import type { Part } from "../foundations/parts"

export type DialogCloseReason = "escape" | "backdrop" | "button" | "action" | "native"

export type DialogOptions = {
  /** Default true. A non-modal dialog uses `show()` and leaves the page interactive. */
  modal?: boolean
  /** "alertdialog" for confirmations that interrupt. Default "dialog". */
  role?: "dialog" | "alertdialog"
  presentation?: "dialog" | "sheet"
  /** Default true for dialogs, false for sheets and alert dialogs. */
  closeOnBackdropPress?: boolean
  /** Default true. */
  closeOnEscape?: boolean
  initialFocus?: FocusTarget
  /** Accessible name when there is no title part. */
  label?: string
  onOpenChange?: (open: boolean) => void
  onClose?: (reason: DialogCloseReason) => void
}

export class DialogController {
  readonly id = createId("dialog")
  readonly titleId = `${this.id}-title`
  readonly descriptionId = `${this.id}-description`
  readonly #options: DialogOptions
  readonly #isOpen: Signal<boolean> = signal(false)
  #dialog: HTMLDialogElement | null = null
  #surface: HTMLElement | null = null
  #layer: DismissLayer | null = null
  #scope: FocusScope | null = null
  #restoreTarget: HTMLElement | null = null
  #hasTitle = false
  #hasDescription = false

  readonly isOpen: ReadSignal<boolean> = this.#isOpen

  constructor(options: DialogOptions = {}) {
    this.#options = options
  }

  get presentation(): "dialog" | "sheet" {
    return this.#options.presentation ?? "dialog"
  }

  open(): void {
    if (this.#isOpen.peek()) return
    // No document at all (a model driven in Node, before any view attached): the state alone.
    const doc = this.#dialog?.ownerDocument ?? (typeof document === "undefined" ? null : document)
    const active = doc?.activeElement ?? null
    this.#restoreTarget = active !== null && doc !== null && active !== doc.body && "focus" in active ? (active as HTMLElement) : null
    const backdrop =
      this.#options.closeOnBackdropPress ?? (this.presentation === "dialog" && this.#options.role !== "alertdialog")
    this.#layer = doc
      ? pushDismissLayer(doc, {
          elements: () => [this.#surface ?? this.#dialog],
          outsidePress: backdrop,
          escape: this.#options.closeOnEscape ?? true,
          onDismiss: (reason) => this.close(reason === "escape" ? "escape" : "backdrop"),
        })
      : null
    this.#isOpen.set(true)
    this.#options.onOpenChange?.(true)
  }

  close(reason: DialogCloseReason = "action"): void {
    if (!this.#isOpen.peek()) return
    this.#layer?.dispose()
    this.#layer = null
    this.#isOpen.set(false)
    const scope = this.#scope
    this.#scope = null
    scope?.deactivate()
    this.#options.onOpenChange?.(false)
    this.#options.onClose?.(reason)
  }

  /** The `<dialog>` element. */
  readonly content: Part = {
    attach: (element) => {
      const dialog = element as HTMLDialogElement
      this.#dialog = dialog
      dialog.id = this.id
      dialog.setAttribute("role", this.#options.role ?? "dialog")
      dialog.setAttribute("data-presentation", this.presentation)
      setAttr(dialog, "aria-modal", (this.#options.modal ?? true) ? "true" : null)
      if (this.#hasTitle) dialog.setAttribute("aria-labelledby", this.titleId)
      else setAttr(dialog, "aria-label", this.#options.label)
      if (this.#hasDescription) dialog.setAttribute("aria-describedby", this.descriptionId)
      const disposers: Dispose[] = [
        effect(() => {
          const open = this.#isOpen.get()
          untracked(() => (open ? this.#show(dialog) : this.#hide(dialog)))
        }),
        // Escape that reaches the platform (or a close request from the OS) arrives as cancel.
        listen(dialog, "cancel", (event: Event) => {
          event.preventDefault()
          if (this.#options.closeOnEscape ?? true) this.close("escape")
        }),
        // A form with method="dialog" closes the element directly.
        listen(dialog, "close", () => this.close("native")),
      ]
      return () => {
        disposeAll(disposers)
        this.#hide(dialog)
        if (this.#dialog === dialog) this.#dialog = null
      }
    },
  }

  /** The visible panel inside the dialog; presses outside it are backdrop presses. */
  readonly surface: Part = {
    attach: (element) => {
      this.#surface = element
      return () => {
        if (this.#surface === element) this.#surface = null
      }
    },
  }

  readonly title: Part = {
    attach: (element) => {
      element.id = this.titleId
      this.#hasTitle = true
      this.#dialog?.setAttribute("aria-labelledby", this.titleId)
      this.#dialog?.removeAttribute("aria-label")
      return () => {
        this.#hasTitle = false
      }
    },
  }

  readonly description: Part = {
    attach: (element) => {
      element.id = this.descriptionId
      this.#hasDescription = true
      this.#dialog?.setAttribute("aria-describedby", this.descriptionId)
      return () => {
        this.#hasDescription = false
      }
    },
  }

  #show(dialog: HTMLDialogElement): void {
    if (!dialog.open && dialog.isConnected) {
      try {
        if (this.#options.modal ?? true) dialog.showModal()
        else dialog.show()
      } catch {
        // Not connected or already open in another mode; the state signal stays the source of truth.
      }
    }
    this.#scope?.deactivate({ restore: false })
    this.#scope = activateFocusScope(dialog, {
      trap: true,
      initialFocus: this.#options.initialFocus,
      finalFocus: () => this.#restoreTarget,
    })
  }

  #hide(dialog: HTMLDialogElement): void {
    if (dialog.open) dialog.close()
  }

  dispose(): void {
    this.close("action")
  }
}

export const createSheet = (options: Omit<DialogOptions, "presentation"> = {}): DialogController =>
  new DialogController({ ...options, presentation: "sheet" })
