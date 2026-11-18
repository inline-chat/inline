/**
 * Toggle: a two-state button (APG "Button", toggle variant, `aria-pressed`)
 * or a switch (APG "Switch", `role="switch"` with `aria-checked`). Render it
 * on a native `<button>` so Enter and Space work without extra handling.
 */

import { effect, type ReadSignal, type Signal, signal } from "@inline/reactive"
import { type Dispose, disposeAll, listen, setAttr } from "../foundations/dom"
import type { Part } from "../foundations/parts"

export type ToggleOptions = {
  pressed?: boolean
  kind?: "button" | "switch"
  disabled?: boolean
  onChange?: (pressed: boolean) => void
}

export class ToggleController {
  readonly #options: ToggleOptions
  readonly #pressed: Signal<boolean>
  readonly #disabled: Signal<boolean>

  readonly pressed: ReadSignal<boolean>
  readonly disabled: ReadSignal<boolean>

  constructor(options: ToggleOptions = {}) {
    this.#options = options
    this.#pressed = signal(options.pressed ?? false)
    this.#disabled = signal(options.disabled ?? false)
    this.pressed = this.#pressed
    this.disabled = this.#disabled
  }

  get kind(): "button" | "switch" {
    return this.#options.kind ?? "button"
  }

  setPressed(pressed: boolean): void {
    if (this.#pressed.peek() === pressed) return
    this.#pressed.set(pressed)
    this.#options.onChange?.(pressed)
  }

  toggle(): void {
    if (!this.#disabled.peek()) this.setPressed(!this.#pressed.peek())
  }

  setDisabled(disabled: boolean): void {
    this.#disabled.set(disabled)
  }

  readonly root: Part = {
    attach: (element) => {
      if (this.kind === "switch") element.setAttribute("role", "switch")
      const disposers: Dispose[] = [
        effect(() => {
          const pressed = String(this.#pressed.get())
          if (this.kind === "switch") element.setAttribute("aria-checked", pressed)
          else element.setAttribute("aria-pressed", pressed)
          setAttr(element, "data-state", this.#pressed.get() ? "on" : "off")
          const disabled = this.#disabled.get()
          if (element instanceof HTMLButtonElement) element.disabled = disabled
          else setAttr(element, "aria-disabled", disabled ? "true" : null)
        }),
        listen(element, "click", () => this.toggle()),
      ]
      return () => disposeAll(disposers)
    },
  }
}
