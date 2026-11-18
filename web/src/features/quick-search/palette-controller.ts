/**
 * The palette's DOM controller: the dialog (top layer, focus trap and
 * restore, Escape and outside press through the kit's dismissal stack), the
 * combobox field, the listbox driven by `aria-activedescendant`, pointer
 * hover, clicks, and keeping the active row in view. Framework-free; the
 * view (`QuickSearchPalette.tsx`) renders rows and hands elements to the
 * parts here.
 *
 * Rules it keeps:
 * - The field keeps DOM focus the whole time; options are never focused.
 * - The field is not controlled by the view: it owns its value while the
 *   user types (so an input method's composition is never disturbed), and
 *   the model's text is written back only when it differs (open, close).
 * - Nothing runs while an input method is composing; the query is set on
 *   `compositionend`.
 * - The active row is revealed only when the keyboard moved it (in the next
 *   frame, after the rows rendered). A new query scrolls to the top.
 * - Pointer movement sets the active row; a pointer event without movement
 *   (a re-render or a scroll under a still pointer) does not.
 */

import { avatarStyle, childId, createId, DialogController, initials, type AvatarStyle, type Part } from "@inline/ui"
import { computed, effect, untracked, type Dispose, type ReadSignal } from "@inline/reactive"
import type { OpenIntent } from "@inline/view"
import type { QuickSearchItem, QuickSearchModel, QuickSearchSectionKind } from "@inline/view/quick-search"
import {
  formatHitDate,
  highlightSegments,
  itemLabel,
  kindLabel,
  paletteKeyAction,
  pointerIntent,
  pointerMoved,
  revealDelta,
  shortcutKeys,
  type TextSegment,
} from "./present"
import type { QuickSearchWiring } from "./wiring"

/** What a row's leading icon shows. */
export type RowVisual =
  | { readonly kind: "photo"; readonly url: string }
  | { readonly kind: "emoji"; readonly emoji: string }
  | { readonly kind: "initials"; readonly initials: string; readonly colors: AvatarStyle; readonly shape: "circle" | "square" }
  | { readonly kind: "command" }
  | { readonly kind: "create" }

/** Everything a row renders, prepared once per item object. */
export type RowPresentation = {
  readonly visual: RowVisual
  readonly title: readonly TextSegment[]
  /** The second text run: the subtitle, or a message's snippet with its highlights. */
  readonly secondary: readonly TextSegment[]
  /** The trailing label: kind, category or a message's time. */
  readonly trailing: string
  /** A command's first shortcut on this platform, as `Kbd` keys. */
  readonly shortcut?: readonly string[]
  readonly label: string
}

export type QuickSearchPaletteControllerOptions = {
  readonly quickSearch: QuickSearchWiring
  /** The dialog's accessible name. */
  readonly label?: string
  /** Runs work in the next frame, after the rows rendered. Default `requestAnimationFrame`. */
  readonly frame?: (fn: () => void) => void
  /** Wall clock for message dates. Default `Date.now`. */
  readonly now?: () => number
}

/** Space kept between a revealed row and the list's edge, in pixels. */
const REVEAL_PADDING = 8
const FACE_LIMIT = 1024

export class QuickSearchPaletteController {
  readonly quickSearch: QuickSearchWiring
  readonly model: QuickSearchModel
  readonly dialog: DialogController
  readonly listId = createId("quick-search")
  readonly inputId = `${this.listId}-input`

  readonly #options: QuickSearchPaletteControllerOptions
  readonly #active = new Map<string, ReadSignal<boolean>>()
  readonly #presentations = new WeakMap<QuickSearchItem, RowPresentation>()
  readonly #faces = new Map<string, AvatarStyle>()
  readonly #initials = new Map<string, string>()
  readonly #disposers: Dispose[] = []
  #input: HTMLInputElement | null = null
  #list: HTMLElement | null = null
  #scroller: HTMLElement | null = null
  #composing = false
  #pointer: { x: number; y: number } | undefined
  #reveal: "active" | "top" | undefined
  #disposed = false

  constructor(options: QuickSearchPaletteControllerOptions) {
    this.#options = options
    this.quickSearch = options.quickSearch
    this.model = options.quickSearch.model
    this.dialog = new DialogController({
      label: options.label ?? "Quick search",
      closeOnBackdropPress: true,
      initialFocus: () => this.#input,
      // Escape, an outside press or the platform's close request: the model closes too.
      onClose: () => {
        if (this.model.isOpen.peek()) this.model.close()
      },
    })
    // The model is the source of truth for open and closed; the dialog follows it.
    this.#disposers.push(
      effect(() => {
        const open = this.model.isOpen.get()
        untracked(() => {
          // The last pointer position is kept: a row that appears under a still pointer is not hovered.
          if (open) {
            this.dialog.open()
          } else {
            this.dialog.close("action")
            this.#active.clear()
            this.#reveal = undefined
          }
        })
      }),
    )
  }

  /** The DOM ID of an item's option. Stable for the item's ID. */
  optionId(itemId: string): string {
    return childId(this.listId, itemId)
  }

  /** The DOM ID of a section's heading. */
  sectionId(kind: QuickSearchSectionKind): string {
    return `${this.listId}-section-${kind}`
  }

  /** Whether an item is the active one. One cached signal per ID, so moving the highlight renders two rows. */
  isActive(itemId: string): ReadSignal<boolean> {
    let active = this.#active.get(itemId)
    if (!active) {
      active = computed(() => this.model.activeId.get() === itemId)
      this.#active.set(itemId, active)
    }
    return active
  }

  /** What a row renders, prepared once per item object (rows are pure). */
  present(item: QuickSearchItem): RowPresentation {
    let presentation = this.#presentations.get(item)
    if (!presentation) {
      presentation = this.#present(item)
      this.#presentations.set(item, presentation)
    }
    return presentation
  }

  /** Activate an item (default: the active one) and perform it. */
  activate(item?: QuickSearchItem, intent: OpenIntent = "here"): void {
    this.quickSearch.activate(item, intent)
  }

  // -------------------------------------------------------------------------
  // Parts

  /** The text field: the combobox. */
  readonly input: Part = {
    attach: (element) => {
      const input = element as HTMLInputElement
      this.#input = input
      input.id = this.inputId
      input.setAttribute("role", "combobox")
      input.setAttribute("aria-autocomplete", "list")
      input.setAttribute("aria-haspopup", "listbox")
      input.setAttribute("aria-controls", this.listId)
      input.setAttribute("autocomplete", "off")
      input.setAttribute("autocapitalize", "off")
      input.setAttribute("autocorrect", "off")
      input.spellcheck = false
      const doc = input.ownerDocument
      const disposers: Dispose[] = [
        effect(() => {
          const open = this.model.isOpen.get()
          input.setAttribute("aria-expanded", open ? "true" : "false")
        }),
        effect(() => {
          // Closed, the results are not observed at all, so store changes cost nothing.
          const id = this.model.isOpen.get() ? this.model.activeId.get() : undefined
          if (id === undefined) input.removeAttribute("aria-activedescendant")
          else input.setAttribute("aria-activedescendant", this.optionId(id))
        }),
        effect(() => {
          const text = this.model.text.get()
          // The field owns its value while typing; write only what differs (open, close).
          if (!this.#composing && input.value !== text) input.value = text
        }),
        listen(input, "input", (event) => {
          if ((event as InputEvent).isComposing || this.#composing) return
          this.#setQuery(input.value)
        }),
        listen(input, "compositionstart", () => {
          this.#composing = true
        }),
        listen(input, "compositionend", () => {
          this.#composing = false
          this.#setQuery(input.value)
        }),
        listen(input, "keydown", (event) => this.#onKeyDown(event as KeyboardEvent)),
        // Every real pointer position, so a pointer event without movement can be told apart.
        listen(doc, "pointermove", (event) => this.#onPointerMove(event as PointerEvent), { capture: true, passive: true }),
      ]
      return () => {
        disposeAll(disposers)
        if (this.#input === input) this.#input = null
      }
    },
  }

  /** The scrolling container around the listbox. */
  readonly scroller: Part = {
    attach: (element) => {
      this.#scroller = element
      element.scrollTop = 0
      return () => {
        if (this.#scroller === element) this.#scroller = null
      }
    },
  }

  /** The listbox. Options carry `data-quick-search-id`. */
  readonly list: Part = {
    attach: (element) => {
      this.#list = element
      element.id = this.listId
      element.setAttribute("role", "listbox")
      element.setAttribute("aria-label", "Results")
      const disposers: Dispose[] = [
        // Keep focus in the field when a row is pressed.
        listen(element, "mousedown", (event) => event.preventDefault()),
        listen(element, "click", (event) => this.#onClick(event as MouseEvent)),
        listen(element, "auxclick", (event) => this.#onClick(event as MouseEvent)),
      ]
      return () => {
        disposeAll(disposers)
        if (this.#list === element) this.#list = null
      }
    },
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    disposeAll(this.#disposers.splice(0))
    this.dialog.dispose()
    this.#active.clear()
  }

  // -------------------------------------------------------------------------
  // Events

  #setQuery(value: string): void {
    const before = this.model.query.peek()
    this.model.setQuery(value)
    if (this.model.query.peek() !== before) this.#scheduleReveal("top")
  }

  #onKeyDown(event: KeyboardEvent): void {
    if (event.defaultPrevented) return
    if (event.isComposing || this.#composing) return
    const input = this.#input
    const action = paletteKeyAction(event, this.quickSearch.platform.os, !input || input.value.length === 0)
    if (!action) return
    event.preventDefault()
    switch (action.kind) {
      case "next":
      case "previous":
      case "first":
      case "last":
      case "nextSection":
      case "previousSection":
        this.model[action.kind]()
        this.#scheduleReveal("active")
        return
      case "activate":
        this.activate(undefined, action.intent)
        return
      case "close":
        this.model.close()
        return
    }
  }

  #onPointerMove(event: PointerEvent): void {
    const position = { x: event.clientX, y: event.clientY }
    const moved = pointerMoved(this.#pointer, position)
    this.#pointer = position
    if (!moved || event.pointerType === "touch" || !this.model.isOpen.peek()) return
    const id = this.#optionAt(event.target)
    if (id !== undefined && id !== this.model.activeId.peek()) this.model.setActive(id)
  }

  #onClick(event: MouseEvent): void {
    const id = this.#optionAt(event.target)
    if (id === undefined) return
    const intent = pointerIntent(event, this.quickSearch.platform.os)
    if (!intent) return
    const item = this.model.items.peek().find((candidate) => candidate.id === id)
    if (!item) return
    event.preventDefault()
    this.activate(item, intent)
  }

  #optionAt(target: EventTarget | null): string | undefined {
    const list = this.#list
    if (!list || !target || !(target as Node).nodeType) return undefined
    const element = (target as Node).nodeType === 1 ? (target as Element) : (target as Node).parentElement
    const option = element?.closest<HTMLElement>("[data-quick-search-id]")
    if (!option || !list.contains(option)) return undefined
    return option.dataset.quickSearchId
  }

  // -------------------------------------------------------------------------
  // Scrolling

  #scheduleReveal(mode: "active" | "top"): void {
    const pending = this.#reveal !== undefined
    this.#reveal = mode
    if (pending) return
    const frame = this.#options.frame ?? ((fn: () => void) => void requestAnimationFrame(() => fn()))
    frame(() => {
      const next = this.#reveal
      this.#reveal = undefined
      if (next && !this.#disposed) this.#applyReveal(next)
    })
  }

  #applyReveal(mode: "active" | "top"): void {
    const scroller = this.#scroller
    if (!scroller || !this.model.isOpen.peek()) return
    const activeId = this.model.activeId.peek()
    if (mode === "top" || activeId === undefined || this.model.items.peek()[0]?.id === activeId) {
      if (scroller.scrollTop !== 0) scroller.scrollTop = 0
      return
    }
    const option = scroller.ownerDocument.getElementById(this.optionId(activeId))
    if (!option) return
    // Read everything first, then write once.
    const view = scroller.getBoundingClientRect()
    const rect = option.getBoundingClientRect()
    let top = rect.top
    // The first row of a section brings its heading into view with it.
    const group = option.parentElement
    if (group?.getAttribute("role") === "group" && group.firstElementChild === option) {
      const headingId = group.getAttribute("aria-labelledby")
      const heading = headingId ? scroller.ownerDocument.getElementById(headingId) : null
      if (heading) top = Math.min(top, heading.getBoundingClientRect().top)
    }
    const delta = revealDelta(view, { top, bottom: rect.bottom }, REVEAL_PADDING)
    if (delta !== 0) scroller.scrollTop += delta
  }

  // -------------------------------------------------------------------------
  // Presentation

  #face(name: string, seed: string, shape: "circle" | "square"): RowVisual {
    let colors = this.#faces.get(seed)
    if (!colors) {
      if (this.#faces.size >= FACE_LIMIT) this.#faces.clear()
      colors = avatarStyle(seed)
      this.#faces.set(seed, colors)
    }
    let letters = this.#initials.get(name)
    if (letters === undefined) {
      if (this.#initials.size >= FACE_LIMIT) this.#initials.clear()
      letters = initials(name)
      this.#initials.set(name, letters)
    }
    return { kind: "initials", initials: letters, colors, shape }
  }

  #personVisual(userId: string, name: string, photo: string | undefined): RowVisual {
    const url = photo ?? this.quickSearch.photoUrl(userId as never)
    return url ? { kind: "photo", url } : this.#face(name, name, "circle")
  }

  #present(item: QuickSearchItem): RowPresentation {
    const title = highlightSegments(item.title, item.titleRanges)
    const subtitle = item.subtitle && item.subtitle !== item.title ? highlightSegments(item.subtitle, []) : []
    switch (item.kind) {
      case "chat": {
        const visual: RowVisual = item.emoji
          ? { kind: "emoji", emoji: item.emoji }
          : item.peerUserId !== undefined
            ? this.#personVisual(item.peerUserId, item.title, undefined)
            : this.#face(item.title, item.title, "circle")
        return { visual, title, secondary: subtitle, trailing: kindLabel(item), label: itemLabel(item) }
      }
      case "user":
        return {
          visual: this.#personVisual(item.userId, item.title, item.user?.photoUrl),
          title,
          secondary: subtitle,
          trailing: kindLabel(item),
          label: itemLabel(item),
        }
      case "space":
        return { visual: this.#face(item.title, item.title, "square"), title, secondary: [], trailing: kindLabel(item), label: itemLabel(item) }
      case "command": {
        const command = this.quickSearch.commands.get(item.commandId)
        const combo = command?.shortcutsFor(this.quickSearch.platform)[0]
        const shortcut = combo ? shortcutKeys(combo, this.quickSearch.platform.os) : undefined
        const extra = combo ? shortcut?.join(" ") : undefined
        return {
          visual: { kind: "command" },
          title,
          secondary: subtitle,
          trailing: kindLabel(item),
          ...(shortcut ? { shortcut } : {}),
          label: itemLabel(item, extra),
        }
      }
      case "createThread":
        return { visual: { kind: "create" }, title, secondary: [], trailing: kindLabel(item), label: itemLabel(item) }
      case "message": {
        const visual =
          item.peerUserId !== undefined ? this.#personVisual(item.peerUserId, item.title, undefined) : this.#face(item.title, item.title, "circle")
        const date = formatHitDate(item.date, (this.#options.now ?? Date.now)())
        return {
          visual,
          title,
          secondary: highlightSegments(item.snippet, item.snippetRanges),
          trailing: date || kindLabel(item),
          label: itemLabel(item, date || undefined),
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// DOM helpers

const listen = (
  target: EventTarget,
  type: string,
  handler: (event: Event) => void,
  options?: AddEventListenerOptions,
): Dispose => {
  target.addEventListener(type, handler, options)
  return () => target.removeEventListener(type, handler, options)
}

const disposeAll = (disposers: Dispose[]): void => {
  for (let index = disposers.length - 1; index >= 0; index--) disposers[index]?.()
}
