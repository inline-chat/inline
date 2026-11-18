/**
 * The full emoji picker: search, category tabs, a virtualized grid, skin
 * tone, a preview line. Framework-free; `EmojiPicker.tsx` renders it.
 *
 * Behavior follows the Mac picker (`apple/InlineMac/Views/Components/EmojiPickerPopover2.swift`):
 *
 * - Sections are Frequently Used (16, from frecency) then the nine
 *   categories, captured when the picker opens so nothing reshuffles under
 *   the pointer (`browseSections`, line 240).
 * - Typing searches with the shared ranking (160 results), and the first
 *   result is highlighted so Return picks it (`setQuery`, lines 548-567).
 * - Focus stays in the search field; arrows move a highlight in the grid,
 *   which the field points at with `aria-activedescendant`. Down from the
 *   field enters the grid at the first emoji; left and right edit the text
 *   until the grid has a highlight (lines 785-821). Escape clears the
 *   search, then closes.
 * - The grid is also a tab stop of its own (WAI-ARIA grid with
 *   `aria-activedescendant`): arrows, Home and End (row), Ctrl+Home and
 *   Ctrl+End (first, last), Page Up and Page Down, Return; typing there
 *   goes to the search field. Left and right follow the writing direction.
 * - Hovering highlights (and previews) the emoji under the pointer.
 *
 * The picker does not record usage; its caller does (a reaction records a
 * pick, the composer records an insert), so nothing is counted twice.
 */

import { computed, effect, signal, untracked, type Dispose, type ReadSignal, type Signal } from "@inline/reactive"
import { directionOf } from "@inline/ui"
import type { EmojiEngine, EmojiInfo, UsageScores } from "./engine"
import {
  columnsFor,
  GRID_METRICS,
  gridMoveForKey,
  insetFor,
  layoutGrid,
  moveInGrid,
  rowPitch,
  samePosition,
  scrollTargetFor,
  sectionAtScroll,
  sectionScrollTop,
  visibleRows,
  type GridLayout,
  type GridPosition,
} from "./grid"
import type { EmojiSupport } from "./support"
import { SKIN_TONES, type SkinTone } from "./tone"
import type { EmojiUsage } from "./usage"

export type PickerItem = {
  /** Unique within the picker. */
  readonly id: string
  /** As shown and as chosen: the base emoji in the preferred tone. */
  readonly emoji: string
  readonly info: EmojiInfo
}

export type PickerSection = { readonly id: string; readonly title: string; readonly items: readonly PickerItem[] }

export type PickerTab = { readonly id: string; readonly title: string; readonly glyph: string; readonly index: number }

export const FREQUENT_SECTION_ID = "frequent"
/** Mac `EmojiPicker2Layout.frequentlyUsedLimit` and `searchResultLimit`. */
export const FREQUENT_LIMIT = 16
export const SEARCH_LIMIT = 160

/** A glyph per category for the tab bar (the Mac uses SF Symbols). */
const TAB_GLYPHS: Readonly<Record<string, string>> = {
  frequent: "🕘",
  smileys: "😀",
  people: "👋",
  animals: "🐻",
  food: "🍔",
  travel: "✈️",
  activities: "⚽",
  objects: "💡",
  symbols: "🔣",
  flags: "🏁",
}

export type KeyInput = {
  readonly key: string
  readonly ctrlKey?: boolean
  readonly metaKey?: boolean
  readonly altKey?: boolean
  readonly shiftKey?: boolean
  readonly isComposing?: boolean
}

export type EmojiPickerOptions = {
  readonly engine: EmojiEngine
  readonly usage: EmojiUsage
  readonly support?: EmojiSupport
  /** An emoji was chosen (in the preferred tone). */
  readonly onChoose: (emoji: string, info: EmojiInfo) => void
  /**
   * Escape with an empty search. Without it Escape is left to the layer the
   * picker is in (a popover closes).
   */
  readonly onRequestClose?: () => void
  /** "rtl" mirrors left and right. Default: the grid element's direction, else "ltr". */
  readonly direction?: () => "ltr" | "rtl"
  /** A search to start with (typed in the reaction row before the picker opened). */
  readonly initialQuery?: string
  /** Focus the search field when it attaches. Default true. */
  readonly autoFocus?: boolean
  /** A prefix for element IDs. */
  readonly idPrefix?: string
}

let nextId = 0

export class EmojiPickerController {
  readonly id: string
  readonly gridId: string
  readonly searchId: string
  readonly previewId: string

  /** The search text as typed. */
  readonly query: ReadSignal<string>
  readonly isSearching: ReadSignal<boolean>
  /** What the grid shows: the browse sections, or one section of results. */
  readonly sections: ReadSignal<readonly PickerSection[]>
  readonly tabs: readonly PickerTab[]
  readonly columns: ReadSignal<number>
  /** The inline inset that centers the columns. */
  readonly inset: ReadSignal<number>
  readonly layout: ReadSignal<GridLayout>
  /** Rows to render, `[start, end)` into `layout.rows`. */
  readonly window: ReadSignal<{ readonly start: number; readonly end: number }>
  readonly highlight: ReadSignal<GridPosition | null>
  /** The tab of the section in view; null while searching. */
  readonly activeTab: ReadSignal<number | null>
  /** The emoji the preview line describes: the highlighted one. */
  readonly preview: ReadSignal<PickerItem | null>
  readonly skinTone: ReadSignal<SkinTone>
  /** The tone choices are showing. */
  readonly toneMenuOpen: ReadSignal<boolean>
  /** The tone choice holding keyboard focus, while the menu is open. */
  readonly toneFocus: ReadSignal<SkinTone>
  /** Nothing matches the search. */
  readonly isEmpty: ReadSignal<boolean>
  /** A sample emoji per tone, for the selector (✋ in each tone). */
  readonly toneSamples: readonly { readonly tone: SkinTone; readonly emoji: string }[]

  readonly #options: EmojiPickerOptions
  readonly #query: Signal<string>
  readonly #highlight = signal<GridPosition | null>(null)
  #highlightSource: "keyboard" | "pointer" = "pointer"
  readonly #width = signal<number>(GRID_METRICS.width)
  readonly #viewport = signal<number>(292)
  readonly #scrollTop = signal<number>(0)
  readonly #toneMenuOpen = signal(false)
  readonly #toneFocus = signal<SkinTone>("standard")
  readonly #browse: Signal<readonly { id: string; title: string; infos: readonly EmojiInfo[] }[]>
  #scores: UsageScores
  readonly #items = new WeakMap<EmojiInfo, Map<SkinTone, PickerItem>>()
  readonly #rowHighlights = new Map<string, ReadSignal<number>>()
  #rowHighlightLayout: GridLayout | undefined
  #gridElement: HTMLElement | null = null
  #searchElement: HTMLInputElement | null = null
  readonly #disposers: Dispose[] = []

  constructor(options: EmojiPickerOptions) {
    this.#options = options
    this.id = options.idPrefix ?? `emoji-picker-${++nextId}`
    this.gridId = `${this.id}-grid`
    this.searchId = `${this.id}-search`
    this.previewId = `${this.id}-preview`
    this.#query = signal(options.initialQuery ?? "")
    this.query = this.#query
    this.#scores = options.usage.scores()
    this.#browse = signal(this.#captureBrowse())
    this.tabs = this.#browse.peek().map((section, index) => ({
      id: section.id,
      title: section.title,
      glyph: TAB_GLYPHS[section.id] ?? "•",
      index,
    }))
    this.skinTone = options.usage.skinTone
    this.toneMenuOpen = this.#toneMenuOpen
    this.toneFocus = this.#toneFocus
    this.toneSamples = SKIN_TONES.map((tone) => ({ tone, emoji: options.engine.withTone("✋", tone) }))

    const trimmed = computed(() => this.#query.get().trim())
    this.isSearching = computed(() => trimmed.get() !== "")

    const searchInfos = computed<readonly EmojiInfo[]>(() => {
      const text = trimmed.get()
      if (text === "") return []
      options.support?.revision.get()
      return options.engine
        .search(text, { limit: SEARCH_LIMIT, usage: this.#scores })
        .filter((info) => options.support?.isSupported(info.emoji) ?? true)
    })

    this.sections = computed<readonly PickerSection[]>(() => {
      const tone = this.skinTone.get()
      if (this.isSearching.get()) {
        const results = searchInfos.get()
        return results.length === 0 ? [] : [{ id: "search", title: "", items: results.map((info) => this.#item(info, tone)) }]
      }
      return this.#browse.get().map((section) => ({ id: section.id, title: section.title, items: section.infos.map((info) => this.#item(info, tone)) }))
    })

    this.columns = computed(() => columnsFor(this.#width.get()))
    this.inset = computed(() => insetFor(this.#width.get(), this.columns.get()))
    this.layout = computed(() => {
      const searching = this.isSearching.get()
      const sections = this.sections.get().map((section) => ({ key: section.id, count: section.items.length, header: !searching && section.title !== "" }))
      return layoutGrid(sections, this.columns.get(), { topInset: searching ? GRID_METRICS.searchTopInset : 0 })
    })
    this.window = computed(
      () => visibleRows(this.layout.get(), this.#scrollTop.get(), this.#viewport.get()),
      { equals: (a, b) => a.start === b.start && a.end === b.end },
    )
    this.highlight = this.#highlight
    this.activeTab = computed(() => {
      if (this.isSearching.get()) return null
      const index = sectionAtScroll(this.layout.get(), this.#scrollTop.get(), this.#viewport.get())
      return index >= 0 && index < this.tabs.length ? index : null
    })
    this.preview = computed(() => {
      const position = this.#highlight.get()
      return position ? this.itemAt(position) ?? null : null
    })
    this.isEmpty = computed(() => this.isSearching.get() && this.sections.get().length === 0)

    if (trimmed.peek() !== "") this.#highlightFirst()
  }

  // Data ---------------------------------------------------------------------

  #captureBrowse() {
    const { engine, usage, support } = this.#options
    const drawable = (info: EmojiInfo) => support?.isSupported(info.emoji) ?? true
    const out: { id: string; title: string; infos: readonly EmojiInfo[] }[] = []
    const frequent = usage
      .frequentlyUsed(FREQUENT_LIMIT, (key) => engine.lookup(key)?.emoji)
      .map((emoji) => engine.lookup(emoji))
      .filter((info): info is EmojiInfo => info !== undefined && drawable(info))
    if (frequent.length > 0) out.push({ id: FREQUENT_SECTION_ID, title: "Frequently Used", infos: frequent })
    for (const section of engine.sections) {
      const infos = section.items.filter(drawable)
      if (infos.length > 0) out.push({ id: section.id, title: section.title, infos })
    }
    return out
  }

  #item(info: EmojiInfo, tone: SkinTone): PickerItem {
    let byTone = this.#items.get(info)
    if (!byTone) this.#items.set(info, (byTone = new Map()))
    let item = byTone.get(tone)
    if (!item) {
      item = { id: `${info.index}`, emoji: this.#options.engine.withTone(info.emoji, tone), info }
      byTone.set(tone, item)
    }
    return item
  }

  itemAt(position: GridPosition): PickerItem | undefined {
    return this.sections.peek()[position.section]?.items[position.item]
  }

  /** The DOM id of a cell, for `aria-activedescendant`. */
  cellId(position: GridPosition): string {
    return `${this.id}-c${position.section}-${position.item}`
  }

  /** Which item of a row is highlighted (-1 for none). One signal per row, so a move re-renders two rows. */
  rowHighlight(section: number, start: number, count: number): ReadSignal<number> {
    const layout = this.layout.peek()
    if (layout !== this.#rowHighlightLayout) {
      this.#rowHighlights.clear()
      this.#rowHighlightLayout = layout
    }
    const key = `${section}:${start}:${count}`
    let cached = this.#rowHighlights.get(key)
    if (!cached) {
      cached = computed(() => {
        const position = this.#highlight.get()
        if (!position || position.section !== section || position.item < start || position.item >= start + count) return -1
        return position.item - start
      })
      this.#rowHighlights.set(key, cached)
    }
    return cached
  }

  // Intent -------------------------------------------------------------------

  setQuery(value: string): void {
    if (value === this.#query.peek()) return
    this.#query.set(value)
    this.#toneMenuOpen.set(false)
    this.#scrollTo(0)
    if (value.trim() === "") this.#setHighlight(null, "pointer")
    else this.#highlightFirst()
  }

  #highlightFirst(): void {
    const sections = this.sections.peek()
    this.#setHighlight(sections[0]?.items[0] ? { section: 0, item: 0 } : null, "keyboard")
  }

  /** Jump to a category: clears the search and scrolls to the section (`selectCategory`). */
  selectTab(index: number): void {
    if (index < 0 || index >= this.tabs.length) return
    if (this.#query.peek() !== "") this.setQuery("")
    this.#setHighlight(null, "pointer")
    this.#scrollTo(sectionScrollTop(this.layout.peek(), index, this.#viewport.peek()))
  }

  /** The pointer is over a cell (or left the grid). */
  hover(position: GridPosition | null): void {
    if (position === null) {
      if (this.#highlightSource === "pointer") this.#setHighlight(null, "pointer")
      return
    }
    if (!this.itemAt(position)) return
    this.#setHighlight(position, "pointer")
  }

  /** Choose an emoji: the highlighted one, or one at a position. */
  choose(position: GridPosition | null = this.#highlight.peek()): boolean {
    if (!position) return false
    const item = this.itemAt(position)
    if (!item) return false
    this.#options.onChoose(item.emoji, item.info)
    return true
  }

  setSkinTone(tone: SkinTone): void {
    this.#options.usage.setSkinTone(tone)
    this.#toneMenuOpen.set(false)
  }

  openToneMenu(): void {
    this.#toneFocus.set(this.skinTone.peek())
    this.#toneMenuOpen.set(true)
  }

  closeToneMenu(): void {
    this.#toneMenuOpen.set(false)
  }

  /** Keys in the tone choices: arrows move (following direction), Return or Space chooses, Escape closes. */
  handleToneKey(input: KeyInput): boolean {
    if (!this.#toneMenuOpen.peek()) return false
    const index = SKIN_TONES.indexOf(this.#toneFocus.peek())
    const rtl = this.#direction() === "rtl"
    const step = (delta: number) => {
      const next = SKIN_TONES[(index + delta + SKIN_TONES.length) % SKIN_TONES.length]
      if (next) this.#toneFocus.set(next)
      return true
    }
    switch (input.key) {
      case "ArrowRight":
        return step(rtl ? -1 : 1)
      case "ArrowLeft":
        return step(rtl ? 1 : -1)
      case "ArrowDown":
        return step(1)
      case "ArrowUp":
        return step(-1)
      case "Home":
        this.#toneFocus.set("standard")
        return true
      case "End":
        this.#toneFocus.set("dark")
        return true
      case "Enter":
      case " ":
        this.setSkinTone(this.#toneFocus.peek())
        this.#searchElement?.focus({ preventScroll: true })
        return true
      case "Escape":
        this.#toneMenuOpen.set(false)
        this.#searchElement?.focus({ preventScroll: true })
        return true
      default:
        return false
    }
  }

  /**
   * A key in the search field (`from: "search"`) or the grid (`"grid"`).
   * Returns true when the picker used it; the caller then prevents the default.
   */
  handleKey(input: KeyInput, from: "search" | "grid"): boolean {
    if (input.isComposing) return false
    if (this.#toneMenuOpen.peek() && this.handleToneKey(input)) return true
    const highlight = this.#highlight.peek()
    const hasModifier = input.ctrlKey || input.metaKey || input.altKey

    if (input.key === "Enter") {
      this.choose()
      return true
    }
    if (input.key === "Escape") {
      if (this.#query.peek() !== "") {
        this.setQuery("")
        return true
      }
      if (this.#options.onRequestClose) {
        this.#options.onRequestClose()
        return true
      }
      return false
    }
    if (input.key === "Tab") return false

    const move = gridMoveForKey(input.key, { rtl: this.#direction() === "rtl", ctrl: input.ctrlKey || input.metaKey })
    if (move) {
      if (from === "search") {
        // Left, right, Home and End edit the text until the grid has a highlight.
        if (move === "previous" || move === "next" || (input.key === "Home" || input.key === "End")) {
          if (!highlight || input.key === "Home" || input.key === "End") return false
        }
      }
      if (!highlight) {
        // Arrowing into the grid starts at the first emoji.
        if (move === "down" || move === "next" || move === "first" || move === "pageDown") this.#moveTo({ section: 0, item: 0 })
        return true
      }
      const pageRows = Math.max(1, Math.floor(this.#viewport.peek() / rowPitch()) - 1)
      const counts = this.sections.peek().map((section) => section.items.length)
      const next = moveInGrid(highlight, move, this.columns.peek(), counts, pageRows)
      if (next) this.#moveTo(next)
      return true
    }

    // Typing in the grid searches.
    if (from === "grid" && !hasModifier && (input.key.length === 1 || input.key === "Backspace")) {
      const current = this.#query.peek()
      this.setQuery(input.key === "Backspace" ? current.slice(0, -1) : current + input.key)
      this.#searchElement?.focus({ preventScroll: true })
      return true
    }
    return false
  }

  #moveTo(position: GridPosition): void {
    if (!this.itemAt(position)) return
    this.#setHighlight(position, "keyboard")
    const target = scrollTargetFor(this.layout.peek(), position, this.#scrollTop.peek(), this.#viewport.peek())
    if (target !== undefined) this.#scrollTo(target)
  }

  #setHighlight(position: GridPosition | null, source: "keyboard" | "pointer"): void {
    this.#highlightSource = source
    if (samePosition(this.#highlight.peek(), position)) return
    this.#highlight.set(position)
  }

  #direction(): "ltr" | "rtl" {
    if (this.#options.direction) return this.#options.direction()
    return directionOf(this.#gridElement ?? this.#searchElement)
  }

  /** The grid scrolled (from the element). */
  setScrollTop(value: number): void {
    this.#scrollTop.set(Math.max(0, value))
  }

  /** The grid's box changed (from the element). */
  setViewport(width: number, height: number): void {
    if (width > 0) this.#width.set(width)
    if (height > 0) this.#viewport.set(height)
  }

  #scrollTo(value: number): void {
    this.#scrollTop.set(value)
    const element = this.#gridElement
    if (element && Math.abs(element.scrollTop - value) > 0.5) element.scrollTop = value
  }

  /** Back to the opening state: no search, sections recaptured, at the top. */
  reset(options: { query?: string } = {}): void {
    this.#scores = this.#options.usage.scores()
    this.#browse.set(this.#captureBrowse())
    this.#toneMenuOpen.set(false)
    this.#query.set(options.query ?? "")
    this.#scrollTo(0)
    if ((options.query ?? "").trim() !== "") this.#highlightFirst()
    else this.#setHighlight(null, "pointer")
  }

  // Parts --------------------------------------------------------------------

  /** The search field (`<input>`): combobox semantics pointing into the grid. */
  readonly search = {
    attach: (element: HTMLInputElement): Dispose => {
      this.#searchElement = element
      element.id = this.searchId
      element.setAttribute("role", "combobox")
      element.setAttribute("aria-autocomplete", "list")
      element.setAttribute("aria-expanded", "true")
      element.setAttribute("aria-controls", this.gridId)
      element.setAttribute("aria-describedby", this.previewId)
      element.autocomplete = "off"
      element.spellcheck = false
      const stops: Dispose[] = [
        effect(() => {
          const query = this.#query.get()
          untracked(() => {
            if (element.value !== query) element.value = query
          })
        }),
        effect(() => {
          const position = this.#highlight.get()
          if (position) element.setAttribute("aria-activedescendant", this.cellId(position))
          else element.removeAttribute("aria-activedescendant")
        }),
      ]
      const onInput = () => this.setQuery(element.value)
      const onKeyDown = (event: KeyboardEvent) => {
        if (!event.defaultPrevented && this.handleKey(event, "search")) {
          event.preventDefault()
          event.stopPropagation()
        }
      }
      // The popover's dismiss stack takes Escape in the document's capture
      // phase. A search to clear or the tone choices to close come first, so
      // Escape is taken here, earlier (the window's capture phase), and marked
      // handled; the stack then leaves it alone.
      const view = element.ownerDocument.defaultView
      const onEscapeFirst = (event: KeyboardEvent) => {
        if (event.key !== "Escape" || event.isComposing || event.defaultPrevented) return
        const root = element.closest("[data-emoji-picker]") ?? element.parentElement
        if (!(event.target instanceof Node) || !root?.contains(event.target)) return
        if (this.#toneMenuOpen.peek()) {
          this.#toneMenuOpen.set(false)
          this.focusSearch()
        } else if (this.#query.peek() !== "") {
          this.setQuery("")
          this.focusSearch()
        } else {
          return
        }
        event.preventDefault()
      }
      view?.addEventListener("keydown", onEscapeFirst, true)
      element.addEventListener("input", onInput)
      element.addEventListener("keydown", onKeyDown)
      if (this.#options.autoFocus ?? true) {
        element.focus({ preventScroll: true })
        const end = element.value.length
        element.setSelectionRange(end, end)
      }
      return () => {
        view?.removeEventListener("keydown", onEscapeFirst, true)
        element.removeEventListener("input", onInput)
        element.removeEventListener("keydown", onKeyDown)
        for (const stop of stops) stop()
        if (this.#searchElement === element) this.#searchElement = null
      }
    },
  }

  /**
   * The grid's scroll container: role, labels, scroll and size tracking,
   * keys, and pointer hover and click by delegation (cells carry
   * `data-section` and `data-item`).
   */
  readonly grid = {
    attach: (element: HTMLElement): Dispose => {
      this.#gridElement = element
      element.id = this.gridId
      element.setAttribute("role", "grid")
      element.setAttribute("aria-label", "Emoji")
      if (!element.hasAttribute("tabindex")) element.tabIndex = 0
      const stops: Dispose[] = [
        effect(() => {
          const layout = this.layout.get()
          // Headers are rows too (a row header spanning the columns), so they count.
          element.setAttribute("aria-rowcount", String(layout.rows.length))
          element.setAttribute("aria-colcount", String(layout.columns))
        }),
        effect(() => {
          const position = this.#highlight.get()
          if (position) element.setAttribute("aria-activedescendant", this.cellId(position))
          else element.removeAttribute("aria-activedescendant")
        }),
      ]
      const positionOf = (target: EventTarget | null): GridPosition | null => {
        const cell = target instanceof Element ? target.closest("[data-item]") : null
        if (!cell || !element.contains(cell)) return null
        const section = Number(cell.getAttribute("data-section"))
        const item = Number(cell.getAttribute("data-item"))
        return Number.isInteger(section) && Number.isInteger(item) ? { section, item } : null
      }
      const onScroll = () => this.setScrollTop(element.scrollTop)
      const onKeyDown = (event: KeyboardEvent) => {
        if (!event.defaultPrevented && this.handleKey(event, "grid")) {
          event.preventDefault()
          event.stopPropagation()
        }
      }
      const onPointerMove = (event: PointerEvent) => {
        if (event.pointerType === "touch") return
        const position = positionOf(event.target)
        if (position && !samePosition(position, this.#highlight.peek())) this.hover(position)
      }
      const onPointerLeave = () => this.hover(null)
      const onClick = (event: MouseEvent) => {
        const position = positionOf(event.target)
        if (position) this.choose(position)
      }
      element.addEventListener("scroll", onScroll, { passive: true })
      element.addEventListener("keydown", onKeyDown)
      element.addEventListener("pointermove", onPointerMove)
      element.addEventListener("pointerleave", onPointerLeave)
      element.addEventListener("click", onClick)
      const measure = () => this.setViewport(element.clientWidth, element.clientHeight)
      measure()
      const Observer = element.ownerDocument.defaultView?.ResizeObserver
      const observer = Observer ? new Observer(() => measure()) : undefined
      observer?.observe(element)
      if (element.scrollTop !== this.#scrollTop.peek()) element.scrollTop = this.#scrollTop.peek()
      return () => {
        observer?.disconnect()
        element.removeEventListener("scroll", onScroll)
        element.removeEventListener("keydown", onKeyDown)
        element.removeEventListener("pointermove", onPointerMove)
        element.removeEventListener("pointerleave", onPointerLeave)
        element.removeEventListener("click", onClick)
        for (const stop of stops) stop()
        if (this.#gridElement === element) this.#gridElement = null
      }
    },
  }

  /**
   * The category bar (a toolbar): one tab stop, arrows move between tabs
   * (following the writing direction), Home and End go to the ends. Tabs
   * carry `data-tab-index`.
   */
  readonly tabBar = {
    attach: (element: HTMLElement): Dispose => {
      element.setAttribute("role", "toolbar")
      element.setAttribute("aria-label", "Categories")
      const onKeyDown = (event: KeyboardEvent) => {
        const buttons = Array.from(element.querySelectorAll<HTMLElement>("[data-tab-index]"))
        const current = buttons.findIndex((button) => button === element.ownerDocument.activeElement)
        if (current < 0) return
        const rtl = (this.#options.direction?.() ?? directionOf(element)) === "rtl"
        let next: number | undefined
        if (event.key === "ArrowRight") next = current + (rtl ? -1 : 1)
        else if (event.key === "ArrowLeft") next = current + (rtl ? 1 : -1)
        else if (event.key === "Home") next = 0
        else if (event.key === "End") next = buttons.length - 1
        if (next === undefined) return
        event.preventDefault()
        const target = buttons[Math.max(0, Math.min(buttons.length - 1, next))]
        for (const button of buttons) button.tabIndex = button === target ? 0 : -1
        target?.focus()
      }
      element.addEventListener("keydown", onKeyDown)
      return () => element.removeEventListener("keydown", onKeyDown)
    },
  }

  readonly #toneParts = new Map<SkinTone, { attach(element: HTMLElement): Dispose }>()

  /** One tone choice (a radio): focus follows `toneFocus`, keys go to `handleToneKey`, a click chooses. */
  toneChoice(tone: SkinTone): { attach(element: HTMLElement): Dispose } {
    let part = this.#toneParts.get(tone)
    if (!part) {
      part = {
        attach: (element) => {
          element.setAttribute("role", "radio")
          const stop = effect(() => {
            const focused = this.#toneFocus.get() === tone
            const checked = this.skinTone.get() === tone
            element.setAttribute("aria-checked", String(checked))
            element.tabIndex = focused ? 0 : -1
            if (focused && this.#toneMenuOpen.get()) untracked(() => element.focus({ preventScroll: true }))
          })
          const onKeyDown = (event: KeyboardEvent) => {
            if (!event.defaultPrevented && this.handleToneKey(event)) {
              event.preventDefault()
              event.stopPropagation()
            }
          }
          const onClick = () => {
            this.setSkinTone(tone)
            this.focusSearch()
          }
          element.addEventListener("keydown", onKeyDown)
          element.addEventListener("click", onClick)
          return () => {
            stop()
            element.removeEventListener("keydown", onKeyDown)
            element.removeEventListener("click", onClick)
          }
        },
      }
      this.#toneParts.set(tone, part)
    }
    return part
  }

  /** Focus the search field (after the tone menu, for example). */
  focusSearch(): void {
    this.#searchElement?.focus({ preventScroll: true })
  }

  /** For diagnostics and the lab: how many rows and cells the grid renders now. */
  renderedCounts(): { rows: number; cells: number } {
    const { start, end } = this.window.peek()
    const rows = this.layout.peek().rows.slice(start, end)
    return { rows: rows.length, cells: rows.reduce((sum, row) => sum + (row.kind === "cells" ? row.count : 0), 0) }
  }

  dispose(): void {
    for (const stop of this.#disposers.splice(0)) stop()
    this.#rowHighlights.clear()
  }
}
