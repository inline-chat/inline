/**
 * Combobox (APG "Combobox" with a listbox popup and list autocomplete):
 * a text field that filters options shown in a popup. Focus stays in the
 * field; the popup's active option is announced with aria-activedescendant.
 *
 * Filtering is either local (`items` plus `filter`) or async (`load`), which
 * gets an AbortSignal and is aborted when the query changes. While a load is
 * in flight the previous results stay on screen, so typing never flashes an
 * empty list.
 */

import { batch, computed, effect, type ReadSignal, type Signal, signal, untracked } from "@inline/reactive"
import { type Clock, systemClock, Timer } from "../foundations/clock"
import { type DismissLayer, pushDismissLayer } from "../foundations/dismiss"
import { type Dispose, disposeAll, listen, setAttr, setBoolAttr } from "../foundations/dom"
import { hideLayer, LAYER_ATTRIBUTE, showLayer, trackLayer } from "../foundations/layer"
import type { PlatformKind } from "../foundations/platform"
import { normalizeText } from "../foundations/typeahead"
import { ListboxController, type ListboxOption } from "../listbox/controller"
import type { SelectionMode } from "../listbox/selection"
import type { Part } from "../foundations/parts"

export type ComboboxStatus = "idle" | "loading" | "error"

export type ComboboxOptions = {
  /** Local options, filtered by `filter`. */
  items?: () => readonly ListboxOption[]
  /** Default: every word of the query is a prefix of a word in the label. */
  filter?: (option: ListboxOption, query: string) => boolean
  /** Async options for a query. Takes precedence over `items`. */
  load?: (query: string, signal: AbortSignal) => Promise<readonly ListboxOption[]>
  /** Wait this long after typing before calling `load`. Default 0. */
  debounce?: number
  selectionMode?: Exclude<SelectionMode, "none">
  selected?: Iterable<string>
  onSelectionChange?: (selected: ReadonlySet<string>) => void
  /** Called when an option is committed with Enter or a click. */
  onCommit?: (option: ListboxOption) => void
  /** Show all options when the field is focused or clicked with an empty query. Default false. */
  openOnFocus?: boolean
  label?: string
  clock?: Clock
  platform?: PlatformKind
}

export const defaultComboboxFilter = (option: ListboxOption, query: string): boolean => {
  const words = normalizeText(query).split(/\s+/).filter(Boolean)
  if (words.length === 0) return true
  const labelWords = normalizeText(option.textValue ?? option.label).split(/[\s\-_/.]+/)
  return words.every((word) => labelWords.some((labelWord) => labelWord.startsWith(word)))
}

export class ComboboxController {
  readonly listbox: ListboxController
  readonly #options: ComboboxOptions
  readonly #query: Signal<string> = signal("")
  readonly #isOpen: Signal<boolean> = signal(false)
  readonly #status: Signal<ComboboxStatus> = signal<ComboboxStatus>("idle")
  readonly #loaded: Signal<readonly ListboxOption[]> = signal<readonly ListboxOption[]>([])
  readonly #results: ReadSignal<readonly ListboxOption[]>
  readonly #debounce: Timer
  #abort: AbortController | null = null
  #input: HTMLInputElement | null = null
  #popup: HTMLElement | null = null
  #layer: DismissLayer | null = null

  readonly query: ReadSignal<string> = this.#query
  readonly isOpen: ReadSignal<boolean> = this.#isOpen
  readonly status: ReadSignal<ComboboxStatus> = this.#status
  readonly results: ReadSignal<readonly ListboxOption[]>

  constructor(options: ComboboxOptions) {
    this.#options = options
    this.#debounce = new Timer(options.clock ?? systemClock)
    this.#results = computed(() => {
      if (options.load) return this.#loaded.get()
      const query = this.#query.get()
      const filter = options.filter ?? defaultComboboxFilter
      return (options.items?.() ?? []).filter((option) => filter(option, query))
    })
    this.results = this.#results
    const multiple = options.selectionMode === "multiple"
    this.listbox = new ListboxController({
      items: () => this.#results.get(),
      selectionMode: options.selectionMode ?? "single",
      selected: options.selected,
      onSelectionChange: options.onSelectionChange,
      selectionFollowsFocus: false,
      activateOnHover: true,
      clickRunsAction: true,
      label: options.label,
      platform: options.platform,
      clock: options.clock,
      onAction: (id) => this.commit(id, { keepOpen: multiple }),
    })
  }

  /** Update the query as the user types: opens the popup and filters. */
  setQuery(text: string): void {
    this.#query.set(text)
    this.open()
    if (this.#options.load) this.#scheduleLoad(text)
    else this.listbox.syncActive("first")
  }

  #scheduleLoad(text: string): void {
    const delay = this.#options.debounce ?? 0
    if (delay > 0) this.#debounce.start(delay, () => void this.#runLoad(text))
    else void this.#runLoad(text)
  }

  async #runLoad(text: string): Promise<void> {
    this.#abort?.abort()
    const abort = new AbortController()
    this.#abort = abort
    this.#status.set("loading")
    try {
      const options = await this.#options.load!(text, abort.signal)
      if (abort.signal.aborted) return
      batch(() => {
        this.#loaded.set(options)
        this.#status.set("idle")
      })
      this.listbox.syncActive("first")
    } catch (error) {
      if (abort.signal.aborted) return
      this.#status.set("error")
      void error
    } finally {
      if (this.#abort === abort) this.#abort = null
    }
  }

  open(): void {
    if (this.#isOpen.peek()) return
    const doc = this.#input?.ownerDocument ?? (typeof document === "undefined" ? null : document)
    if (doc) {
      this.#layer = pushDismissLayer(doc, {
        elements: () => [this.#popup],
        ignore: () => [this.#input],
        focusOutside: true,
        onDismiss: () => this.close(),
      })
    }
    this.#isOpen.set(true)
    if (this.#options.load && this.#loaded.peek().length === 0 && !this.#abort) this.#scheduleLoad(this.#query.peek())
    this.listbox.syncActive("keep")
  }

  close(): void {
    if (!this.#isOpen.peek()) return
    this.#layer?.dispose()
    this.#layer = null
    this.#debounce.stop()
    batch(() => {
      this.#isOpen.set(false)
      this.listbox.setActive(null)
    })
  }

  /** Choose an option: select it, put its label in the field (single), and close (single). */
  commit(id: string, options: { keepOpen?: boolean } = {}): void {
    const option = this.#results.peek().find((candidate) => candidate.id === id)
    if (!option || option.disabled) return
    if (this.listbox.selection.mode === "multiple") this.listbox.selection.toggle(id)
    else {
      this.listbox.selection.replace(id)
      this.#query.set(option.label)
      if (this.#input) this.#input.value = option.label
    }
    if (!options.keepOpen) this.close()
    this.#options.onCommit?.(option)
  }

  handleKeyDown(event: KeyboardEvent | { key: string; altKey?: boolean; shiftKey?: boolean }): boolean {
    const open = this.#isOpen.peek()
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      if (event.altKey) {
        if (event.key === "ArrowDown") this.open()
        else this.close()
        return true
      }
      if (!open) {
        this.open()
        this.listbox.syncActive("first")
        if (event.key === "ArrowUp") this.listbox.handleKeyDown({ key: "End" })
        return true
      }
      return this.listbox.handleKeyDown(event, { typeahead: false })
    }
    if (!open) {
      if (event.key === "Escape" && this.#query.peek() !== "") {
        this.setQuery("")
        this.close()
        if (this.#input) this.#input.value = ""
        return true
      }
      return false
    }
    if (event.key === "Enter") {
      const active = this.listbox.activeId.peek()
      if (active === null) return false
      this.commit(active, { keepOpen: this.listbox.selection.mode === "multiple" })
      return true
    }
    if (event.key === "PageDown" || event.key === "PageUp") return this.listbox.handleKeyDown(event, { typeahead: false })
    return false
  }

  /** The text field. */
  readonly input: Part = {
    attach: (element) => {
      const input = element as HTMLInputElement
      this.#input = input
      input.setAttribute("role", "combobox")
      input.setAttribute("aria-autocomplete", "list")
      input.setAttribute("autocomplete", "off")
      input.setAttribute("aria-controls", this.listbox.id)
      const disposers: Dispose[] = [
        effect(() => {
          const open = this.#isOpen.get()
          const active = this.listbox.activeId.get()
          setBoolAttr(input, "aria-expanded", open)
          setAttr(input, "aria-activedescendant", open && active !== null ? this.listbox.optionDomId(active) : null)
          setAttr(input, "aria-busy", this.#status.get() === "loading" ? "true" : null)
        }),
        listen(input, "input", () => this.setQuery(input.value)),
        listen(input, "keydown", (event: KeyboardEvent) => {
          if (event.isComposing) return
          if (this.handleKeyDown(event)) event.preventDefault()
        }),
        listen(input, "focus", () => {
          if (this.#options.openOnFocus) this.open()
        }),
        listen(input, "click", () => {
          if (this.#options.openOnFocus) this.open()
        }),
      ]
      return () => {
        disposeAll(disposers)
        if (this.#input === input) this.#input = null
      }
    },
  }

  /** The popup element (the view renders the listbox inside it, or makes it the listbox). */
  readonly popup: Part = {
    attach: (element) => {
      this.#popup = element
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
          if (this.#input) element.style.setProperty("--ui-anchor-width", `${this.#input.getBoundingClientRect().width}px`)
          stopTracking = trackLayer(element, {
            anchor: () => this.#input,
            placement: "bottom-start",
            offset: 4,
            padding: 8,
          })
        })
      })
      return () => {
        stopTracking?.()
        dispose()
        hideLayer(element)
        if (this.#popup === element) this.#popup = null
      }
    },
  }

  dispose(): void {
    this.#abort?.abort()
    this.close()
  }
}
