/**
 * Tabs (APG "Tabs"): a tablist with a roving tab index. Arrows move focus
 * between tabs (wrapping), following the writing direction; with automatic
 * activation the focused tab is selected, with manual activation Enter or
 * Space selects it. Home and End jump to the ends.
 */

import { computed, effect, type ReadSignal, type Signal, signal } from "@inline/reactive"
import { navigate } from "../foundations/collection"
import { type Dispose, directionOf, disposeAll, focusElement, type KeyInput, listen, setAttr } from "../foundations/dom"
import { childId, createId } from "../foundations/id"
import type { Part } from "../foundations/parts"

export type TabSpec = { readonly id: string; readonly disabled?: boolean }

export type TabsOptions = {
  tabs: () => readonly TabSpec[]
  selected?: string
  activation?: "automatic" | "manual"
  orientation?: "horizontal" | "vertical"
  onChange?: (id: string) => void
  label?: string
}

export class TabsController {
  readonly id = createId("tabs")
  readonly #options: TabsOptions
  readonly #tabs: ReadSignal<readonly TabSpec[]>
  readonly #selected: Signal<string | null>
  /** The tab that holds the tab stop; differs from selected during manual activation. */
  readonly #focused: Signal<string | null>
  readonly #elements = new Map<string, HTMLElement>()
  readonly #tabParts = new Map<string, Part>()
  readonly #panelParts = new Map<string, Part>()
  readonly #selectedSignals = new Map<string, ReadSignal<boolean>>()
  #list: HTMLElement | null = null

  readonly selectedId: ReadSignal<string | null>

  constructor(options: TabsOptions) {
    this.#options = options
    this.#tabs = computed(() => options.tabs())
    const initial = options.selected ?? navigate(this.#tabs.peek(), null, "first")
    this.#selected = signal(initial)
    this.#focused = signal(initial)
    this.selectedId = this.#selected
  }

  tabDomId(id: string): string {
    return childId(this.id, `tab-${id}`)
  }

  panelDomId(id: string): string {
    return childId(this.id, `panel-${id}`)
  }

  isSelected(id: string): ReadSignal<boolean> {
    let cached = this.#selectedSignals.get(id)
    if (!cached) {
      cached = computed(() => this.#selected.get() === id)
      this.#selectedSignals.set(id, cached)
    }
    return cached
  }

  select(id: string): void {
    const tab = this.#tabs.peek().find((candidate) => candidate.id === id)
    if (!tab || tab.disabled) return
    this.#focused.set(id)
    if (this.#selected.peek() === id) return
    this.#selected.set(id)
    this.#options.onChange?.(id)
  }

  handleKeyDown(event: KeyInput): boolean {
    const vertical = this.#options.orientation === "vertical"
    const rtl = !vertical && directionOf(this.#list) === "rtl"
    const nextKey = vertical ? "ArrowDown" : rtl ? "ArrowLeft" : "ArrowRight"
    const prevKey = vertical ? "ArrowUp" : rtl ? "ArrowRight" : "ArrowLeft"
    const tabs = this.#tabs.peek()
    const current = this.#focused.peek()
    let target: string | null = null
    if (event.key === nextKey) target = navigate(tabs, current, "next", { loop: true })
    else if (event.key === prevKey) target = navigate(tabs, current, "prev", { loop: true })
    else if (event.key === "Home") target = navigate(tabs, current, "first")
    else if (event.key === "End") target = navigate(tabs, current, "last")
    else if ((event.key === "Enter" || event.key === " ") && current !== null) {
      this.select(current)
      return true
    }
    if (target === null) return false
    this.#focused.set(target)
    focusElement(this.#elements.get(target))
    if ((this.#options.activation ?? "automatic") === "automatic") this.select(target)
    return true
  }

  readonly list: Part = {
    attach: (element) => {
      this.#list = element
      element.setAttribute("role", "tablist")
      setAttr(element, "aria-orientation", this.#options.orientation === "vertical" ? "vertical" : null)
      setAttr(element, "aria-label", this.#options.label)
      const dispose = listen(element, "keydown", (event: KeyboardEvent) => {
        if (event.target instanceof Element && event.target.getAttribute("role") !== "tab") return
        if (this.handleKeyDown(event)) event.preventDefault()
      })
      return () => {
        dispose()
        if (this.#list === element) this.#list = null
      }
    },
  }

  tab(id: string): Part {
    let part = this.#tabParts.get(id)
    if (!part) {
      part = {
        attach: (element) => {
          this.#elements.set(id, element)
          element.id = this.tabDomId(id)
          element.setAttribute("role", "tab")
          element.setAttribute("aria-controls", this.panelDomId(id))
          const disposers: Dispose[] = [
            effect(() => {
              const selected = this.#selected.get() === id
              const focusable = (this.#focused.get() ?? this.#selected.get()) === id
              element.setAttribute("aria-selected", String(selected))
              element.tabIndex = focusable ? 0 : -1
              const tab = this.#tabs.get().find((candidate) => candidate.id === id)
              setAttr(element, "aria-disabled", tab?.disabled ? "true" : null)
            }),
            listen(element, "click", () => this.select(id)),
            listen(element, "focus", () => this.#focused.set(id)),
          ]
          return () => {
            disposeAll(disposers)
            if (this.#elements.get(id) === element) this.#elements.delete(id)
          }
        },
      }
      this.#tabParts.set(id, part)
    }
    return part
  }

  panel(id: string): Part {
    let part = this.#panelParts.get(id)
    if (!part) {
      part = {
        attach: (element) => {
          element.id = this.panelDomId(id)
          element.setAttribute("role", "tabpanel")
          element.setAttribute("aria-labelledby", this.tabDomId(id))
          if (!element.hasAttribute("tabindex")) element.tabIndex = 0
          return effect(() => {
            element.hidden = this.#selected.get() !== id
          }) satisfies Dispose
        },
      }
      this.#panelParts.set(id, part)
    }
    return part
  }
}
