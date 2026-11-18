/**
 * Listbox (APG "Listbox"): a list of options with single or multiple
 * selection. Focus stays on the listbox; the active option is announced with
 * `aria-activedescendant`, so the same controller drives a combobox popup
 * whose focus stays in the text field.
 *
 * Desktop selection: arrows move the active option and, by default, the
 * selection with it (as macOS lists do); Shift extends a range; the platform
 * modifier (Cmd on Mac, Ctrl elsewhere) toggles; Mod+A selects all.
 * With `selectionFollowsFocus: false` it is the APG model: arrows move focus
 * and Space toggles.
 */

import { computed, effect, type ReadSignal, type Signal, signal } from "@inline/reactive"
import type { Clock } from "../foundations/clock"
import { isUsable, type NavAction, navigate } from "../foundations/collection"
import { type Dispose, disposeAll, isPrintableKey, type KeyInput, listen, setAttr } from "../foundations/dom"
import { childId, createId } from "../foundations/id"
import { detectPlatform, hasCommandModifier, type PlatformKind } from "../foundations/platform"
import { Typeahead } from "../foundations/typeahead"
import type { Part } from "../foundations/parts"
import { type SelectionMode, SelectionModel } from "./selection"

export type ListboxOption = {
  readonly id: string
  readonly label: string
  readonly disabled?: boolean
  readonly textValue?: string
}

export type ListboxOptions = {
  items: () => readonly ListboxOption[]
  selectionMode?: SelectionMode
  selected?: Iterable<string>
  onSelectionChange?: (selected: ReadonlySet<string>) => void
  /** Arrows move the selection with the active option. Default true. */
  selectionFollowsFocus?: boolean
  /** Enter or double click on an option. */
  onAction?: (id: string) => void
  label?: string
  loop?: boolean
  pageSize?: number
  platform?: PlatformKind
  clock?: Clock
  /** Move the active option with the pointer (combobox popups). Default false. */
  activateOnHover?: boolean
  /** A click runs `onAction` instead of selecting (combobox popups commit on click). Default false. */
  clickRunsAction?: boolean
}

export type ListboxRootOptions = {
  /** False when focus lives elsewhere (a combobox input); the root then takes no focus and no keys. */
  focusable?: boolean
}

export class ListboxController {
  readonly id = createId("listbox")
  readonly selection: SelectionModel
  readonly #options: ListboxOptions
  readonly #active: Signal<string | null> = signal<string | null>(null)
  readonly #items: ReadSignal<readonly ListboxOption[]>
  readonly #typeahead: Typeahead
  readonly #platform: PlatformKind
  readonly #elements = new Map<string, HTMLElement>()
  readonly #parts = new Map<string, Part>()
  readonly #activeSignals = new Map<string, ReadSignal<boolean>>()
  readonly #selectedSignals = new Map<string, ReadSignal<boolean>>()
  #root: HTMLElement | null = null

  readonly activeId: ReadSignal<string | null> = this.#active
  readonly items: ReadSignal<readonly ListboxOption[]>

  constructor(options: ListboxOptions) {
    this.#options = options
    this.#items = computed(() => options.items())
    this.items = this.#items
    this.selection = new SelectionModel({
      mode: options.selectionMode ?? "single",
      initial: options.selected,
      onChange: options.onSelectionChange,
    })
    this.#typeahead = new Typeahead({ clock: options.clock })
    this.#platform = options.platform ?? detectPlatform()
  }

  get selected(): ReadSignal<ReadonlySet<string>> {
    return this.selection.selected
  }

  optionDomId(id: string): string {
    return childId(this.id, id)
  }

  isActive(id: string): ReadSignal<boolean> {
    let cached = this.#activeSignals.get(id)
    if (!cached) {
      cached = computed(() => this.#active.get() === id)
      this.#activeSignals.set(id, cached)
    }
    return cached
  }

  isSelected(id: string): ReadSignal<boolean> {
    let cached = this.#selectedSignals.get(id)
    if (!cached) {
      cached = computed(() => this.selection.selected.get().has(id))
      this.#selectedSignals.set(id, cached)
    }
    return cached
  }

  #order(): string[] {
    return this.#items
      .peek()
      .filter((item) => !item.disabled)
      .map((item) => item.id)
  }

  /** Make an option active (the keyboard cursor) and scroll it into view. */
  setActive(id: string | null): void {
    this.#active.set(id)
    if (id !== null) this.#elements.get(id)?.scrollIntoView?.({ block: "nearest" })
  }

  /** Keep the active option valid after the items change (filtering). */
  syncActive(prefer: "first" | "keep" = "keep"): void {
    const items = this.#items.peek()
    const current = this.#active.peek()
    if (prefer === "keep" && isUsable(items, current)) return
    this.#active.set(navigate(items, null, "first"))
  }

  #move(action: NavAction, event: KeyInput): void {
    const next = navigate(this.#items.peek(), this.#active.peek(), action, {
      loop: this.#options.loop,
      pageSize: this.#options.pageSize,
    })
    if (next === null) return
    this.setActive(next)
    if (this.selection.mode === "none") return
    if (event.shiftKey && this.selection.mode === "multiple") this.selection.extendTo(next, this.#order())
    else if (this.#options.selectionFollowsFocus ?? true) this.selection.replace(next)
  }

  /** Select an option the way a click with these modifiers does. */
  selectWithModifiers(id: string, modifiers: Pick<KeyInput, "shiftKey" | "metaKey" | "ctrlKey"> = {}): void {
    const item = this.#items.peek().find((candidate) => candidate.id === id)
    if (!item || item.disabled) return
    this.#active.set(id)
    if (this.selection.mode === "none") return
    if (modifiers.shiftKey && this.selection.mode === "multiple") this.selection.extendTo(id, this.#order())
    else if (hasCommandModifier(modifiers, this.#platform)) this.selection.toggle(id)
    else this.selection.replace(id)
  }

  /** Handle a key for the listbox (or for a combobox input driving it). Returns true when handled. */
  handleKeyDown(event: KeyInput, options: { typeahead?: boolean; homeEnd?: boolean } = {}): boolean {
    const multiple = this.selection.mode === "multiple"
    switch (event.key) {
      case "ArrowDown":
        this.#move("next", event)
        return true
      case "ArrowUp":
        this.#move("prev", event)
        return true
      case "Home":
        if (options.homeEnd === false) return false
        this.#move("first", event)
        return true
      case "End":
        if (options.homeEnd === false) return false
        this.#move("last", event)
        return true
      case "PageDown":
        this.#move("pageDown", event)
        return true
      case "PageUp":
        this.#move("pageUp", event)
        return true
      case "Enter": {
        const active = this.#active.peek()
        if (active === null) return false
        this.#options.onAction?.(active)
        return true
      }
      case " ": {
        if (this.#typeahead.active && options.typeahead !== false) break
        const active = this.#active.peek()
        if (active === null || this.selection.mode === "none") return true
        if (event.shiftKey && multiple) this.selection.extendTo(active, this.#order())
        else if (multiple) this.selection.toggle(active)
        else this.selection.replace(active)
        return true
      }
    }
    if ((event.key === "a" || event.key === "A") && multiple && hasCommandModifier(event, this.#platform)) {
      this.selection.selectAll(this.#order())
      return true
    }
    if (options.typeahead !== false && isPrintableKey(event)) {
      const match = this.#typeahead.type(
        event.key,
        this.#items.peek().map((item) => ({ id: item.id, text: item.textValue ?? item.label, disabled: item.disabled })),
        this.#active.peek(),
      )
      if (match !== null) {
        this.setActive(match)
        if (this.selection.mode !== "none" && (this.#options.selectionFollowsFocus ?? true)) this.selection.replace(match)
      }
      return true
    }
    return false
  }

  /** The listbox element, focusable, handling keys itself. */
  readonly root: Part = this.#rootPart({ focusable: true })
  /** The listbox element when focus lives elsewhere (a combobox input drives it). */
  readonly passiveRoot: Part = this.#rootPart({ focusable: false })

  #rootPart(options: ListboxRootOptions): Part {
    return {
      attach: (element) => {
        this.#root = element
        element.id = this.id
        element.setAttribute("role", "listbox")
        setAttr(element, "aria-label", this.#options.label)
        setAttr(element, "aria-multiselectable", this.selection.mode === "multiple" ? "true" : null)
        const focusable = options.focusable ?? true
        const disposers: Dispose[] = []
        if (focusable) {
          if (!element.hasAttribute("tabindex")) element.tabIndex = 0
          disposers.push(
            effect(() => {
              const active = this.#active.get()
              setAttr(element, "aria-activedescendant", active === null ? null : this.optionDomId(active))
            }),
            listen(element, "focus", () => {
              if (this.#active.peek() !== null) return
              const firstSelected = this.#items.peek().find((item) => this.selection.isSelected(item.id))
              this.setActive(firstSelected?.id ?? navigate(this.#items.peek(), null, "first"))
            }),
            listen(element, "keydown", (event: KeyboardEvent) => {
              if (event.defaultPrevented) return
              if (this.handleKeyDown(event)) event.preventDefault()
            }),
          )
        }
        return () => {
          disposeAll(disposers)
          if (this.#root === element) this.#root = null
        }
      },
    }
  }

  option(id: string): Part {
    let part = this.#parts.get(id)
    if (!part) {
      part = { attach: (element) => this.#attachOption(id, element) }
      this.#parts.set(id, part)
    }
    return part
  }

  #attachOption(id: string, element: HTMLElement): Dispose {
    this.#elements.set(id, element)
    element.id = this.optionDomId(id)
    element.setAttribute("role", "option")
    const disposers: Dispose[] = [
      effect(() => {
        const item = this.#items.get().find((candidate) => candidate.id === id)
        setAttr(element, "aria-disabled", item?.disabled ? "true" : null)
        const selectable = this.selection.mode !== "none"
        setAttr(element, "aria-selected", selectable ? String(this.selection.selected.get().has(id)) : null)
        setAttr(element, "data-active", this.#active.get() === id)
      }),
      // mousedown keeps focus where it is (the listbox, or a combobox input).
      listen(element, "mousedown", (event: MouseEvent) => event.preventDefault()),
      listen(element, "click", (event: MouseEvent) => {
        const item = this.#items.peek().find((candidate) => candidate.id === id)
        if (this.#options.clickRunsAction) {
          if (item && !item.disabled) {
            this.#active.set(id)
            this.#options.onAction?.(id)
          }
          return
        }
        this.selectWithModifiers(id, event)
        if (this.#root && this.#root.tabIndex >= 0) this.#root.focus({ preventScroll: true })
      }),
      listen(element, "dblclick", () => this.#options.onAction?.(id)),
    ]
    if (this.#options.activateOnHover) {
      disposers.push(
        listen(element, "pointermove", (event: PointerEvent) => {
          if (event.pointerType === "touch") return
          const item = this.#items.peek().find((candidate) => candidate.id === id)
          if (item && !item.disabled && this.#active.peek() !== id) this.#active.set(id)
        }),
      )
    }
    return () => {
      disposeAll(disposers)
      if (this.#elements.get(id) === element) this.#elements.delete(id)
    }
  }
}
