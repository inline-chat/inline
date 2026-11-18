/**
 * The settings region's model: which page is listed as current, the search
 * field and its results, revealing a searched row, and which column shows
 * at a narrow width. Framework-free; the view renders it and hands it
 * elements through parts.
 *
 * The page itself is not owned here: it comes from the `settings`
 * destination, and choosing a page calls `onNavigate`, so the URL and Back go
 * through the workspace. `destination(page)` is the part the view attaches to
 * keep the page list in step when the destination changes from outside
 * (Back, Forward, a link).
 */

import { computed, effect, signal, type ReadSignal } from "@inline/reactive"
import { ListboxController, systemClock, type Clock, type Part, type PlatformKind, type TimerHandle } from "@inline/ui"
import type { SettingsPage } from "@inline/view"
import {
  findItem,
  resolvePage,
  SETTINGS_ITEMS,
  visiblePages,
  type ResolvedPage,
  type SettingsItemSpec,
  type SettingsPageId,
  type SettingsPageSpec,
} from "./catalog"
import { buildSearchIndex, searchSettings, type SettingsSearchEntry } from "./search"

/** How long a revealed row stays highlighted (the Mac app's 1.2 s). */
export const REVEAL_HIGHLIGHT_MS = 1200

export type NarrowView = "list" | "page"

export type SettingsModelOptions = {
  /** The destination's page at creation. */
  readonly page: SettingsPage | undefined
  readonly hasAccount: boolean
  /** Change the destination's page: the shell opens `{ kind: "settings", page }` in this pane. */
  readonly onNavigate: (page: SettingsPage) => void
  readonly clock?: Clock
  /** For the listboxes' Cmd or Ctrl handling. */
  readonly platform?: PlatformKind
  /** Rows to index. Default: every row in the catalog. */
  readonly items?: readonly SettingsItemSpec[]
}

/** The minimal element surface the model touches, so tests can pass plain objects. */
type RevealTarget = Pick<HTMLElement, "querySelector"> & {
  scrollIntoView?: (options?: ScrollIntoViewOptions) => void
}

const FOCUSABLE =
  'input:not([disabled]), button:not([disabled]), select:not([disabled]), textarea:not([disabled]), a[href], [tabindex]:not([tabindex="-1"])'

export class SettingsModel {
  readonly pages: readonly SettingsPageSpec[]
  readonly index: readonly SettingsSearchEntry[]
  /** The destination's page as last synced (undefined for `/settings`). */
  readonly destinationPage: ReadSignal<SettingsPage | undefined>
  readonly resolved: ReadSignal<ResolvedPage>
  readonly query: ReadSignal<string>
  readonly searching: ReadSignal<boolean>
  readonly results: ReadSignal<readonly SettingsSearchEntry[]>
  /** At a narrow width, which column shows. Ignored when both fit. */
  readonly narrowView: ReadSignal<NarrowView>
  /** The page list: arrows move the selection and the destination with it, as in the Mac sidebar. */
  readonly pageList: ListboxController
  /** Search results, driven from the search field (APG combobox with an always-visible listbox). */
  readonly resultList: ListboxController
  /**
   * An element around the page list (the kit `Listbox` attaches
   * `pageList.root` itself): a click on a page shows it at a narrow width,
   * where arrow keys only move through the list.
   */
  readonly pageListFrame: Part
  /** The search `<input>`. */
  readonly searchField: Part

  readonly #options: SettingsModelOptions
  readonly #clock: Clock
  readonly #destination = signal<SettingsPage | undefined>(undefined)
  readonly #query = signal("")
  readonly #narrowView = signal<NarrowView>("list")
  readonly #highlighted = signal<string | null>(null)
  readonly #highlightSignals = new Map<string, ReadSignal<boolean>>()
  readonly #rows = new Map<string, RevealTarget>()
  readonly #rowParts = new Map<string, Part>()
  readonly #destinationParts = new Map<string, Part>()
  readonly #timers = new Set<TimerHandle>()
  #highlightTimer: TimerHandle | null = null
  #pending: { readonly id: string; readonly focus: boolean } | null = null
  #requested: SettingsPage | undefined
  #syncing = false
  #pageListFrame: HTMLElement | null = null
  #disposed = false

  constructor(options: SettingsModelOptions) {
    this.#options = options
    this.#clock = options.clock ?? systemClock
    this.pages = visiblePages({ hasAccount: options.hasAccount })
    this.index = buildSearchIndex(this.pages, options.items ?? SETTINGS_ITEMS)
    this.#destination.set(options.page)
    this.#narrowView.set(options.page === undefined ? "list" : "page")
    this.destinationPage = this.#destination
    this.resolved = computed(() => resolvePage(this.#destination.get(), this.pages))
    this.query = this.#query
    this.searching = computed(() => this.#query.get().trim() !== "")
    this.results = computed(() => searchSettings(this.#query.get(), this.index))
    this.narrowView = this.#narrowView

    const initial = resolvePage(options.page, this.pages)
    this.pageList = new ListboxController({
      items: () => this.pages.map((page) => ({ id: page.id, label: page.title })),
      selectionMode: "single",
      selected: initial.kind === "page" ? [initial.id] : [],
      selectionFollowsFocus: true,
      onSelectionChange: (selected) => {
        if (this.#syncing) return
        const [id] = selected
        if (id !== undefined) this.#navigate(id as SettingsPageId)
      },
      onAction: (id) => this.openPage(id as SettingsPageId),
      label: "Settings pages",
      ...(options.platform ? { platform: options.platform } : {}),
      clock: this.#clock,
    })
    this.resultList = new ListboxController({
      items: () => this.results.get().map((result) => ({ id: result.id, label: result.title })),
      selectionMode: "none",
      clickRunsAction: true,
      activateOnHover: true,
      onAction: (id) => this.reveal(id, { focus: true }),
      label: "Search results",
      ...(options.platform ? { platform: options.platform } : {}),
      clock: this.#clock,
    })

    this.pageListFrame = {
      attach: (element) => {
        this.#pageListFrame = element
        const onClick = (event: Event) => {
          const target = event.target as Element | null
          if (target?.closest?.('[role="option"]')) this.#narrowView.set("page")
        }
        element.addEventListener("click", onClick)
        return () => {
          element.removeEventListener("click", onClick)
          if (this.#pageListFrame === element) this.#pageListFrame = null
        }
      },
    }

    this.searchField = {
      attach: (element) => {
        const input = element as HTMLInputElement
        input.setAttribute("role", "combobox")
        input.setAttribute("aria-autocomplete", "list")
        input.setAttribute("aria-controls", this.resultList.id)
        const stop = effect(() => {
          const searching = this.searching.get()
          const active = this.resultList.activeId.get()
          input.setAttribute("aria-expanded", String(searching))
          if (searching && active !== null) input.setAttribute("aria-activedescendant", this.resultList.optionDomId(active))
          else input.removeAttribute("aria-activedescendant")
        })
        const onKeyDown = (event: KeyboardEvent) => {
          if (event.defaultPrevented || event.isComposing) return
          if (this.handleSearchKey(event)) {
            event.preventDefault()
            if (event.key === "Escape") {
              input.value = ""
              event.stopPropagation()
            }
          }
        }
        input.addEventListener("keydown", onKeyDown)
        return () => {
          stop()
          input.removeEventListener("keydown", onKeyDown)
        }
      },
    }
  }

  /** The current page as the view should render it. */
  current(): ResolvedPage {
    return this.resolved.peek()
  }

  /**
   * The part that keeps the list in step with the destination. The view
   * attaches `destination(props.page)` to its root; a new page gives a new
   * part, so the sync runs at commit, not during render.
   */
  destination(page: SettingsPage | undefined): Part {
    const key = page ?? ""
    let part = this.#destinationParts.get(key)
    if (!part) {
      part = {
        attach: () => {
          this.syncDestination(page)
          return () => undefined
        },
      }
      this.#destinationParts.set(key, part)
    }
    return part
  }

  /** The destination changed (or is confirmed). Updates the list without navigating again. */
  syncDestination(page: SettingsPage | undefined): void {
    if (this.#disposed) return
    const echo = page !== undefined && page === this.#requested
    this.#requested = undefined
    if (page === this.#destination.peek()) return
    this.#destination.set(page)
    const resolved = resolvePage(page, this.pages)
    this.#syncing = true
    try {
      this.pageList.selection.set(resolved.kind === "page" ? [resolved.id] : [])
    } finally {
      this.#syncing = false
    }
    // Move the keyboard cursor only once the list has one: the kit draws the active option outlined.
    if (resolved.kind === "page" && this.pageList.activeId.peek() !== null) this.pageList.setActive(resolved.id)
    // Our own navigation keeps the narrow column as it is; one from outside shows what it opened.
    if (!echo) this.#narrowView.set(page === undefined ? "list" : "page")
  }

  /** The user chose a page (click, Enter, a search result): show it. */
  openPage(page: SettingsPageId): void {
    this.#narrowView.set("page")
    if (page !== this.#destination.peek()) this.#navigate(page)
  }

  /** The narrow layout's back control: show the list and focus it. */
  showList(): void {
    this.#narrowView.set("list")
    this.#later(() => this.#pageListBox()?.focus({ preventScroll: true }))
  }

  setQuery(text: string): void {
    this.#query.set(text)
    this.resultList.syncActive("first")
  }

  /**
   * Keys in the search field. Returns true when handled. While searching:
   * arrows move through the results, Enter reveals the active one (or the
   * first), Escape clears. With no query, Down moves focus to the page list.
   */
  handleSearchKey(event: Pick<KeyboardEvent, "key" | "shiftKey" | "altKey" | "ctrlKey" | "metaKey">): boolean {
    if (this.searching.peek()) {
      if (event.key === "Escape") {
        this.setQuery("")
        return true
      }
      if (event.key === "Enter") {
        const id = this.resultList.activeId.peek() ?? this.results.peek()[0]?.id
        if (id === undefined) return true
        this.reveal(id, { focus: true })
        return true
      }
      if (event.key === "ArrowDown" || event.key === "ArrowUp" || event.key === "PageDown" || event.key === "PageUp") {
        return this.resultList.handleKeyDown(event, { typeahead: false, homeEnd: false })
      }
      return false
    }
    const list = event.key === "ArrowDown" ? this.#pageListBox() : null
    if (list) {
      list.focus()
      return true
    }
    return false
  }

  /**
   * Go to a row: open its page, scroll the row into view, highlight it for
   * a moment, and with `focus` move focus to its first control.
   */
  reveal(id: string, options: { readonly focus?: boolean } = {}): void {
    const spec = findItem(id)
    if (!spec || !this.pages.some((page) => page.id === spec.page)) return
    const focus = options.focus ?? false
    const resolved = this.resolved.peek()
    const row = this.#rows.get(id)
    this.#narrowView.set("page")
    if (row && resolved.kind === "page" && resolved.id === spec.page) {
      this.#later(() => this.#revealRow(id, row, focus))
      return
    }
    this.#pending = { id, focus }
    this.openPage(spec.page)
  }

  /** The element of a row, for `reveal`. Cached per row. */
  row(id: string): Part {
    let part = this.#rowParts.get(id)
    if (!part) {
      part = {
        attach: (element) => {
          this.#rows.set(id, element)
          const pending = this.#pending
          if (pending?.id === id) {
            this.#pending = null
            this.#later(() => this.#revealRow(id, element, pending.focus))
          }
          return () => {
            if (this.#rows.get(id) === element) this.#rows.delete(id)
          }
        },
      }
      this.#rowParts.set(id, part)
    }
    return part
  }

  /** True while a revealed row is highlighted. One signal per row. */
  isHighlighted(id: string): ReadSignal<boolean> {
    let cached = this.#highlightSignals.get(id)
    if (!cached) {
      cached = computed(() => this.#highlighted.get() === id)
      this.#highlightSignals.set(id, cached)
    }
    return cached
  }

  dispose(): void {
    this.#disposed = true
    for (const timer of this.#timers) this.#clock.clearTimeout(timer)
    this.#timers.clear()
    this.#clock.clearTimeout(this.#highlightTimer)
    this.#highlightTimer = null
    this.#rows.clear()
    this.#pending = null
  }

  #pageListBox(): HTMLElement | null {
    return this.#pageListFrame?.querySelector<HTMLElement>('[role="listbox"]') ?? null
  }

  #navigate(page: SettingsPageId): void {
    this.#requested = page
    this.#options.onNavigate(page)
  }

  /** After the view has rendered what a signal change asked for (a hidden column is not focusable). */
  #later(fn: () => void): void {
    if (this.#disposed) return
    const timer = this.#clock.setTimeout(() => {
      this.#timers.delete(timer)
      if (!this.#disposed) fn()
    }, 0)
    this.#timers.add(timer)
  }

  #revealRow(id: string, row: RevealTarget, focus: boolean): void {
    row.scrollIntoView?.({ block: "center" })
    if (focus) row.querySelector<HTMLElement>(FOCUSABLE)?.focus({ preventScroll: true })
    this.#clock.clearTimeout(this.#highlightTimer)
    this.#highlighted.set(id)
    this.#highlightTimer = this.#clock.setTimeout(() => {
      this.#highlightTimer = null
      if (this.#highlighted.peek() === id) this.#highlighted.set(null)
    }, REVEAL_HIGHLIGHT_MS)
  }
}
