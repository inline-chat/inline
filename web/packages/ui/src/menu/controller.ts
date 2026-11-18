/**
 * Menu (WAI-ARIA APG "Menu Button" and "Menu"): a list of commands in a top
 * layer, with submenus, checkable items, separators, typeahead and hover
 * intent. Data-driven: the controller is given entries and owns highlight,
 * open state, focus and keyboard; the view renders entries and attaches parts.
 *
 * Structure the view renders (no portals; submenus are siblings of their item):
 *
 *   <button ref={trigger}/>
 *   <div ref={content} popover="manual">           role=menu
 *     <div ref={item(a)}/>                          role=menuitem
 *     <div ref={item(sub)}/>                        role=menuitem, aria-haspopup=menu
 *     <div ref={submenu(sub).content}>...</div>     only while open
 *   </div>
 */

import { batch, computed, effect, type ReadSignal, type Signal, signal, untracked } from "@inline/reactive"
import { type Clock, systemClock, Timer } from "../foundations/clock"
import { navigate } from "../foundations/collection"
import { type DismissLayer, type DismissReason, pushDismissLayer } from "../foundations/dismiss"
import {
  activeElementOf,
  contains,
  type Dispose,
  directionOf,
  disposeAll,
  focusElement,
  isPrintableKey,
  type KeyInput,
  listen,
  type Rect,
  rectOf,
  setAttr,
  setBoolAttr,
} from "../foundations/dom"
import { HoverIntent } from "../foundations/hover-intent"
import { childId, createId } from "../foundations/id"
import { hideLayer, LAYER_ATTRIBUTE, type PlaceOptions, showLayer, trackLayer } from "../foundations/layer"
import type { Part } from "../foundations/parts"
import type { Placement } from "../foundations/position"
import { ariaKeyShortcutsFromHint } from "../foundations/shortcuts"
import { Typeahead } from "../foundations/typeahead"

type Entries = readonly MenuEntry[] | (() => readonly MenuEntry[])

type ItemBase = {
  id: string
  label: string
  disabled?: boolean
  /** Shortcut hint to display, e.g. "⌘C". Matching is the command registry's job. Hidden from assistive technology. */
  shortcut?: string
  /**
   * The same shortcut for assistive technology, as `aria-keyshortcuts`
   * ("Meta+C", "Control+Shift+E"). Build it from the command's combo with
   * `ariaKeyShortcuts`; without it, it is derived from `shortcut` when that
   * parses (`ariaKeyShortcutsFromHint`).
   */
  keyshortcuts?: string
  /** Text used for typeahead when the label is not plain text. */
  textValue?: string
  /** Keep the menu open after activation. */
  keepOpen?: boolean
}

export type MenuEntry =
  | (ItemBase & { type: "item"; destructive?: boolean; onSelect?: () => void })
  | (ItemBase & { type: "checkbox"; checked: boolean; onCheckedChange?: (checked: boolean) => void })
  | (ItemBase & { type: "radio"; checked: boolean; onSelect?: () => void })
  | (Omit<ItemBase, "keepOpen" | "shortcut"> & { type: "submenu"; items: Entries })
  | { type: "separator"; id: string }
  | { type: "label"; id: string; label: string }

export type FocusableEntry = Extract<MenuEntry, { type: "item" | "checkbox" | "radio" | "submenu" }>

export type MenuOptions = {
  items: Entries
  /** Accessible name when there is no trigger (context menus). */
  label?: string
  placement?: Placement
  offset?: number
  /** Wrap arrow navigation at the ends. macOS menus do not; default false. */
  loop?: boolean
  clock?: Clock
  /** Hover time before a submenu opens. Default 100ms. */
  submenuOpenDelay?: number
  /** Grace period for the safe triangle toward an open submenu. Default 300ms. */
  submenuGrace?: number
  /** Called for every activated entry, after its own handler (for the command registry). */
  onAction?: (entry: MenuEntry) => void
  onOpenChange?: (open: boolean) => void
  document?: Document
}

export type MenuOpenOptions = {
  /** Which item to highlight. Keyboard opening highlights first or last; pointer opening none. */
  highlight?: "first" | "last" | "none"
  /** Move focus into the menu when it shows. Default true. */
  focus?: boolean
  /** Anchor to a point or rectangle instead of the trigger (context menus). */
  anchor?: Rect
  /**
   * Where focus returns on close, when known better than "what has focus
   * now" (a context menu whose code loaded after the request).
   */
  returnFocus?: HTMLElement | null
}

export type CloseOptions = { restoreFocus?: boolean }

export type { Part } from "../foundations/parts"

const resolveEntries = (entries: Entries): readonly MenuEntry[] => (typeof entries === "function" ? entries() : entries)

export const isFocusableEntry = (entry: MenuEntry): entry is FocusableEntry =>
  entry.type === "item" || entry.type === "checkbox" || entry.type === "radio" || entry.type === "submenu"

const roleFor = (entry: FocusableEntry) =>
  entry.type === "checkbox" ? "menuitemcheckbox" : entry.type === "radio" ? "menuitemradio" : "menuitem"

const keyShortcutsOf = (entry: Exclude<FocusableEntry, { type: "submenu" }>): string | null =>
  entry.keyshortcuts ?? (entry.shortcut ? ariaKeyShortcutsFromHint(entry.shortcut) : undefined) ?? null

const isMousePointer = (event: PointerEvent) => event.pointerType === "mouse" || event.pointerType === "pen"

export class MenuController {
  readonly id: string
  readonly triggerId: string
  readonly parent: MenuController | null
  /** The entry ID in the parent that opens this submenu. */
  readonly parentItemId: string | null

  readonly #options: MenuOptions
  readonly #clock: Clock
  readonly #isOpen: Signal<boolean> = signal(false)
  readonly #highlighted: Signal<string | null> = signal<string | null>(null)
  readonly #openSubmenu: Signal<string | null> = signal<string | null>(null)
  readonly #entries: ReadSignal<readonly MenuEntry[]>
  readonly #typeahead: Typeahead
  readonly #submenuTimer: Timer
  readonly #intent: HoverIntent
  readonly #submenus = new Map<string, MenuController>()
  readonly #itemElements = new Map<string, HTMLElement>()
  readonly #itemParts = new Map<string, Part>()
  readonly #highlightSignals = new Map<string, ReadSignal<boolean>>()
  #triggerElement: HTMLElement | null = null
  #contentElement: HTMLElement | null = null
  #layer: DismissLayer | null = null
  #restoreTarget: HTMLElement | null = null
  #anchor: Rect | null = null
  #focusOnShow = true
  #pendingHover: string | null = null
  #suppressClick = false
  #pointerToggled = false
  #submenuTimerFor: string | null = null

  readonly isOpen: ReadSignal<boolean> = this.#isOpen
  readonly highlightedId: ReadSignal<string | null> = this.#highlighted
  readonly openSubmenuId: ReadSignal<string | null> = this.#openSubmenu
  readonly entries: ReadSignal<readonly MenuEntry[]>

  constructor(options: MenuOptions, parent: MenuController | null = null, parentItemId: string | null = null) {
    this.#options = options
    this.parent = parent
    this.parentItemId = parentItemId
    this.id = createId("menu")
    this.triggerId = `${this.id}-trigger`
    this.#clock = options.clock ?? systemClock
    this.#entries = computed(() => resolveEntries(this.#options.items))
    this.entries = this.#entries
    this.#typeahead = new Typeahead({ clock: this.#clock })
    this.#submenuTimer = new Timer(this.#clock)
    this.#intent = new HoverIntent({
      clock: this.#clock,
      grace: options.submenuGrace ?? 300,
      onExpire: () => this.#applyPendingHover(),
    })
  }

  get root(): MenuController {
    return this.parent ? this.parent.root : this
  }

  get level(): number {
    return this.parent ? this.parent.level + 1 : 0
  }

  // MARK: State

  entry(id: string): MenuEntry | undefined {
    return this.#entries.peek().find((entry) => entry.id === id)
  }

  #focusables(): FocusableEntry[] {
    return this.#entries.peek().filter(isFocusableEntry)
  }

  /** A per-item signal, so each item view re-renders only when its own highlight changes. */
  isHighlighted(id: string): ReadSignal<boolean> {
    let cached = this.#highlightSignals.get(id)
    if (!cached) {
      cached = computed(() => this.#highlighted.get() === id)
      this.#highlightSignals.set(id, cached)
    }
    return cached
  }

  /** The controller for the submenu opened by entry `id`. */
  submenu(id: string): MenuController {
    let child = this.#submenus.get(id)
    if (!child) {
      child = new MenuController(
        {
          ...this.#options,
          items: () => {
            const entry = this.#entries.get().find((candidate) => candidate.id === id)
            return entry?.type === "submenu" ? resolveEntries(entry.items) : []
          },
          placement: "inline-end-start",
          offset: 0,
          onOpenChange: undefined,
        },
        this,
        id,
      )
      this.#submenus.set(id, child)
    }
    return child
  }

  itemDomId(id: string): string {
    return childId(this.id, id)
  }

  // MARK: Open and close

  open(options: MenuOpenOptions = {}): void {
    if (this.#isOpen.peek()) {
      if (options.highlight === "first" || options.highlight === "last") this.#highlightEdge(options.highlight)
      return
    }
    const doc = this.#document()
    if (!this.parent && doc) {
      const active = options.returnFocus !== undefined ? options.returnFocus : activeElementOf(doc)
      this.#restoreTarget = active instanceof HTMLElement && active !== doc.body ? active : this.#triggerElement
    }
    this.#anchor = options.anchor ?? null
    this.#focusOnShow = options.focus ?? true
    if (doc) {
      this.#layer = pushDismissLayer(doc, {
        elements: () => [this.#contentElement],
        ignore: () => [this.#triggerElement],
        parent: this.parent ? this.parent.#layer : null,
        focusOutside: !this.parent,
        onDismiss: (reason) => this.#onDismiss(reason),
      })
    }
    // Showing, placing and focusing happen in the content part's effect.
    batch(() => {
      this.#isOpen.set(true)
      const highlight = options.highlight ?? "none"
      this.#highlighted.set(
        highlight === "none" ? null : navigate(this.#focusables(), null, highlight === "first" ? "first" : "last"),
      )
    })
    this.#options.onOpenChange?.(true)
  }

  close(options: CloseOptions = {}): void {
    if (!this.#isOpen.peek()) return
    for (const child of this.#submenus.values()) child.close({ restoreFocus: false })
    const doc = this.#document()
    const focusInside = doc ? this.#focusIsInside(doc) : false
    this.#submenuTimer.stop()
    this.#intent.end()
    this.#typeahead.reset()
    this.#pendingHover = null
    this.#layer?.dispose()
    this.#layer = null
    batch(() => {
      this.#isOpen.set(false)
      this.#highlighted.set(null)
      this.#openSubmenu.set(null)
      if (this.parent && this.parentItemId && this.parent.#openSubmenu.peek() === this.parentItemId) {
        this.parent.#openSubmenu.set(null)
      }
    })
    if (this.#contentElement) hideLayer(this.#contentElement)
    if ((options.restoreFocus ?? true) && focusInside) {
      if (this.parent && this.parentItemId) this.parent.highlight(this.parentItemId)
      else focusElement(this.#restoreTarget, true)
    }
    if (!this.parent) this.#restoreTarget = null
    this.#options.onOpenChange?.(false)
  }

  /** Close the whole chain from the root. */
  closeAll(options: CloseOptions = {}): void {
    this.root.close(options)
  }

  toggle(options: MenuOpenOptions = {}): void {
    if (this.#isOpen.peek()) this.close()
    else this.open(options)
  }

  #onDismiss(reason: DismissReason): void {
    if (reason === "escape") this.close({ restoreFocus: true })
    else if (reason === "outside-press") this.close({ restoreFocus: !this.parent })
    else this.closeAll({ restoreFocus: false })
  }

  #focusIsInside(doc: Document): boolean {
    const active = activeElementOf(doc)
    if (!active || active === doc.body || !active.isConnected) return true
    return this.#containsInTree(active)
  }

  #containsInTree(node: Node): boolean {
    if (contains(this.#contentElement, node)) return true
    for (const child of this.#submenus.values()) if (child.#containsInTree(node)) return true
    return false
  }

  #document(): Document | null {
    return (
      this.#options.document ??
      this.#triggerElement?.ownerDocument ??
      this.#contentElement?.ownerDocument ??
      (this.parent ? this.parent.#document() : null) ??
      (typeof document === "undefined" ? null : document)
    )
  }

  // MARK: Highlight and activation

  /** Highlight an item (or none) and move focus to it when the menu is shown. */
  highlight(id: string | null, options: { focus?: boolean } = {}): void {
    this.#highlighted.set(id)
    if (options.focus === false || !this.#contentElement || !this.#isOpen.peek()) return
    const element = id === null ? null : this.#itemElements.get(id)
    if (element) {
      focusElement(element, true)
      element.scrollIntoView?.({ block: "nearest" })
    } else {
      focusElement(this.#contentElement, true)
    }
  }

  #highlightEdge(edge: "first" | "last"): void {
    this.highlight(navigate(this.#focusables(), null, edge))
  }

  openSubmenu(id: string, options: MenuOpenOptions = {}): void {
    const entry = this.entry(id)
    if (entry?.type !== "submenu" || entry.disabled) return
    this.#submenuTimer.stop()
    const current = this.#openSubmenu.peek()
    if (current && current !== id) this.#submenus.get(current)?.close({ restoreFocus: false })
    this.#openSubmenu.set(id)
    const child = this.submenu(id)
    child.#anchor = null
    child.open(options)
  }

  /** Activate an item as if clicked or chosen with Enter. */
  activate(id: string): void {
    const entry = this.entry(id)
    if (!entry || !isFocusableEntry(entry) || entry.disabled) return
    if (entry.type === "submenu") {
      this.openSubmenu(id, { highlight: "first" })
      return
    }
    // Close before running the handler, so a dialog it opens records the
    // trigger, not a vanishing menu item, as the place to return focus to.
    if (!entry.keepOpen) this.closeAll({ restoreFocus: true })
    if (entry.type === "checkbox") entry.onCheckedChange?.(!entry.checked)
    else entry.onSelect?.()
    this.#options.onAction?.(entry)
  }

  // MARK: Keyboard

  /** Handle a key pressed inside this level's content. Returns true when handled. */
  handleKeyDown(event: KeyInput): boolean {
    const focusables = this.#focusables()
    const current = this.#highlighted.peek()
    const rtl = directionOf(this.#contentElement) === "rtl"
    const forward = rtl ? "ArrowLeft" : "ArrowRight"
    const back = rtl ? "ArrowRight" : "ArrowLeft"
    const loop = this.#options.loop ?? false
    switch (event.key) {
      case "ArrowDown":
        this.highlight(navigate(focusables, current, "next", { loop }))
        return true
      case "ArrowUp":
        this.highlight(navigate(focusables, current, "prev", { loop }))
        return true
      case "Home":
      case "PageUp":
        this.highlight(navigate(focusables, current, "first"))
        return true
      case "End":
      case "PageDown":
        this.highlight(navigate(focusables, current, "last"))
        return true
      case forward: {
        const entry = current === null ? undefined : this.entry(current)
        if (entry?.type === "submenu" && !entry.disabled && current !== null) {
          if (this.#openSubmenu.peek() === current) this.submenu(current).#highlightEdge("first")
          else this.openSubmenu(current, { highlight: "first" })
        }
        return true
      }
      case back:
        if (this.parent) this.close({ restoreFocus: true })
        return true
      case "Enter":
        if (current !== null) this.activate(current)
        return true
      case " ":
        if (this.#typeahead.active) break
        if (current !== null) this.activate(current)
        return true
      case "Tab":
        // Close and put focus back on the trigger; the browser then moves on from there.
        this.closeAll({ restoreFocus: true })
        return false
    }
    if (isPrintableKey(event)) {
      const match = this.#typeahead.type(
        event.key,
        focusables.map((entry) => ({ id: entry.id, text: entry.textValue ?? entry.label, disabled: entry.disabled })),
        current,
      )
      if (match !== null) this.highlight(match)
      return true
    }
    return false
  }

  // MARK: Pointer

  #onItemPointerMove(id: string, event: PointerEvent): void {
    if (!isMousePointer(event)) return
    if (this.#intent.active && this.#intent.isInTransit({ x: event.clientX, y: event.clientY })) {
      this.#pendingHover = id
      return
    }
    this.#pendingHover = null
    this.#hover(id)
  }

  #hover(id: string): void {
    const entry = this.entry(id)
    if (!entry || !isFocusableEntry(entry) || entry.disabled) {
      this.#closeOpenSubmenu()
      if (this.#highlighted.peek() !== null) this.highlight(null)
      return
    }
    if (this.#highlighted.peek() !== id) this.highlight(id)
    if (entry.type === "submenu") {
      if (this.#openSubmenu.peek() !== id && !(this.#submenuTimer.running && this.#submenuTimerFor === id)) {
        this.#closeOpenSubmenu()
        this.#submenuTimerFor = id
        this.#submenuTimer.start(this.#options.submenuOpenDelay ?? 100, () =>
          this.openSubmenu(id, { highlight: "none", focus: false }),
        )
      }
    } else {
      this.#submenuTimer.stop()
      this.#closeOpenSubmenu()
    }
  }

  #closeOpenSubmenu(): void {
    const open = this.#openSubmenu.peek()
    if (open !== null) this.#submenus.get(open)?.close({ restoreFocus: false })
  }

  #onItemPointerLeave(id: string, event: PointerEvent): void {
    if (!isMousePointer(event)) return
    if (this.#submenuTimer.running && this.#openSubmenu.peek() !== id) this.#submenuTimer.stop()
    if (this.#openSubmenu.peek() !== id) return
    const child = this.#submenus.get(id)
    const submenuContent = child ? child.#contentElement : null
    if (!submenuContent) return
    this.#intent.begin({ x: event.clientX, y: event.clientY }, rectOf(submenuContent))
  }

  #applyPendingHover(): void {
    const pending = this.#pendingHover
    this.#pendingHover = null
    if (pending !== null) this.#hover(pending)
  }

  /** The pointer reached this submenu: the parent's intent is fulfilled. */
  #onContentPointerEnter(): void {
    if (!this.parent) return
    this.parent.#intent.end()
    this.parent.#pendingHover = null
    if (this.parentItemId && this.parent.#highlighted.peek() !== this.parentItemId) {
      this.parent.#highlighted.set(this.parentItemId)
    }
  }

  #onContentPointerLeave(event: PointerEvent): void {
    if (!isMousePointer(event) || this.#openSubmenu.peek() !== null || this.#intent.active) return
    this.highlight(null)
  }

  // MARK: Parts

  readonly trigger: Part = {
    attach: (element) => {
      this.#triggerElement = element
      element.id = this.triggerId
      setAttr(element, "aria-haspopup", "menu")
      const disposers: Dispose[] = [
        effect(() => {
          const open = this.#isOpen.get()
          setBoolAttr(element, "aria-expanded", open)
          setAttr(element, "aria-controls", open ? this.id : null)
          setAttr(element, "data-state", open ? "open" : "closed")
        }),
        listen(element, "pointerdown", (event: PointerEvent) => {
          this.#pointerToggled = false
          if (!isMousePointer(event) || event.button !== 0 || event.ctrlKey) return
          event.preventDefault()
          this.#pointerToggled = true
          element.focus({ preventScroll: true })
          this.toggle({ highlight: "none" })
        }),
        listen(element, "keydown", (event: KeyboardEvent) => {
          const highlight =
            event.key === "Enter" || event.key === " " || event.key === "ArrowDown"
              ? "first"
              : event.key === "ArrowUp"
                ? "last"
                : null
          if (!highlight) return
          event.preventDefault()
          this.#pointerToggled = false
          this.#suppressClick = event.key === " "
          if (this.#isOpen.peek() && event.key !== "ArrowDown" && event.key !== "ArrowUp") this.close()
          else this.open({ highlight })
        }),
        listen(element, "keyup", (event: KeyboardEvent) => {
          if (event.key === " ") queueMicrotask(() => (this.#suppressClick = false))
        }),
        listen(element, "click", (event: MouseEvent) => {
          if (this.#suppressClick) {
            this.#suppressClick = false
            return
          }
          // Mouse presses were handled on pointerdown. Touch, pen taps and
          // assistive technology (detail 0) toggle here.
          if (this.#pointerToggled) {
            this.#pointerToggled = false
            return
          }
          this.toggle({ highlight: event.detail === 0 ? "first" : "none" })
        }),
      ]
      return () => {
        disposeAll(disposers)
        if (this.#triggerElement === element) this.#triggerElement = null
      }
    },
  }

  readonly content: Part = {
    attach: (element) => {
      this.#contentElement = element
      element.id = this.id
      element.tabIndex = -1
      element.setAttribute("role", "menu")
      element.setAttribute(LAYER_ATTRIBUTE, "")
      if (!element.hasAttribute("popover")) element.setAttribute("popover", "manual")
      if (this.parent && this.parentItemId) setAttr(element, "aria-labelledby", this.parent.itemDomId(this.parentItemId))
      else if (this.#triggerElement) setAttr(element, "aria-labelledby", this.triggerId)
      else setAttr(element, "aria-label", this.#options.label)
      const owns = (event: Event) =>
        event.target instanceof Element && event.target.closest("[role='menu']") === element
      let stopTracking: Dispose | null = null
      const disposers: Dispose[] = [
        effect(() => {
          const open = this.#isOpen.get()
          untracked(() => {
            if (open) {
              this.#show(element)
              stopTracking?.()
              stopTracking = trackLayer(element, this.#placeOptions())
            } else {
              stopTracking?.()
              stopTracking = null
              hideLayer(element)
            }
          })
        }),
        listen(element, "keydown", (event: KeyboardEvent) => {
          if (!owns(event) || event.defaultPrevented) return
          if (this.handleKeyDown(event)) {
            event.preventDefault()
            event.stopPropagation()
          }
        }),
        listen(element, "pointerenter", () => this.#onContentPointerEnter()),
        listen(element, "pointerleave", (event: PointerEvent) => this.#onContentPointerLeave(event)),
        listen(element, "contextmenu", (event: MouseEvent) => {
          if (owns(event)) event.preventDefault()
        }),
      ]
      return () => {
        stopTracking?.()
        disposeAll(disposers)
        hideLayer(element)
        if (this.#contentElement === element) this.#contentElement = null
      }
    },
  }

  /** The part for entry `id`. Cached, so a view can pass it to `useElement` every render. */
  item(id: string): Part {
    let part = this.#itemParts.get(id)
    if (!part) {
      part = { attach: (element) => this.#attachItem(id, element) }
      this.#itemParts.set(id, part)
    }
    return part
  }

  #attachItem(id: string, element: HTMLElement): Dispose {
    this.#itemElements.set(id, element)
    element.id = this.itemDomId(id)
    element.tabIndex = -1
    const disposers: Dispose[] = [
      effect(() => {
        const entry = this.#entries.get().find((candidate) => candidate.id === id)
        if (!entry) return
        if (entry.type === "separator") {
          element.setAttribute("role", "separator")
          return
        }
        if (entry.type === "label") {
          element.setAttribute("role", "presentation")
          element.removeAttribute("tabindex")
          return
        }
        element.setAttribute("role", roleFor(entry))
        // The name is the label alone: the visible shortcut glyphs are not part of it (APG Menu).
        element.setAttribute("aria-label", entry.label)
        setAttr(element, "aria-keyshortcuts", entry.type === "submenu" ? null : keyShortcutsOf(entry))
        setAttr(element, "aria-disabled", entry.disabled ? "true" : null)
        setAttr(element, "aria-checked", entry.type === "checkbox" || entry.type === "radio" ? String(entry.checked) : null)
        if (entry.type === "submenu") {
          const open = this.#openSubmenu.get() === id
          element.setAttribute("aria-haspopup", "menu")
          setBoolAttr(element, "aria-expanded", open)
          setAttr(element, "aria-controls", open ? this.submenu(id).id : null)
        }
      }),
      effect(() => setAttr(element, "data-highlighted", this.#highlighted.get() === id)),
      listen(element, "pointermove", (event: PointerEvent) => this.#onItemPointerMove(id, event)),
      listen(element, "pointerleave", (event: PointerEvent) => this.#onItemPointerLeave(id, event)),
      listen(element, "click", (event: MouseEvent) => {
        event.preventDefault()
        if (this.entry(id)?.type === "submenu") this.openSubmenu(id, { highlight: "none", focus: false })
        else this.activate(id)
      }),
    ]
    // A view that mounts items after the content (Solid order) still gets focus right.
    if (this.#isOpen.peek() && this.#highlighted.peek() === id && this.#focusOnShow) focusElement(element, true)
    return () => {
      disposeAll(disposers)
      if (this.#itemElements.get(id) === element) this.#itemElements.delete(id)
    }
  }

  #placeOptions(): PlaceOptions {
    const anchor = (): Element | Rect | null => {
      if (this.parent && this.parentItemId) return this.parent.#itemElements.get(this.parentItemId) ?? null
      return this.#anchor ?? this.#triggerElement
    }
    return {
      anchor,
      placement: this.#options.placement ?? "bottom-start",
      offset: this.#options.offset ?? 4,
      alignOffset: this.parent ? -5 : 0,
      padding: 8,
      flipAlign: !!this.#anchor || !!this.parent,
    }
  }

  #show(element: HTMLElement): void {
    showLayer(element)
    if (!this.#focusOnShow) return
    const highlighted = this.#highlighted.peek()
    const item = highlighted === null ? null : this.#itemElements.get(highlighted)
    focusElement(item ?? element, true)
  }

  dispose(): void {
    this.close({ restoreFocus: false })
    for (const child of this.#submenus.values()) child.dispose()
    this.#submenus.clear()
  }
}

export const createMenu = (options: MenuOptions): MenuController => new MenuController(options)
