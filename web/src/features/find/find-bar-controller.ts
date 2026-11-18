/**
 * The find bar's DOM controller: the combobox field, the list of previews
 * with a bounded window of rows, and row presentation. Framework-free; the
 * view (`FindBar.tsx`) renders it and hands it elements through parts.
 *
 * - The field keeps DOM focus the whole time (`aria-activedescendant` names
 *   the current preview). It is not a controlled input: it owns its value
 *   while typing, and the model's text is written back only when it
 *   differs (open, close, a seed), so an input method's composition is
 *   never disturbed. Nothing is searched while composing.
 * - Keys handled in the field are `preventDefault`ed, so the app's keyboard
 *   dispatcher (which ignores prevented events) never sees them.
 * - The list scrolls itself (its own scroll position, never the
 *   timeline's), renders only the rows near its viewport, keeps the
 *   current row in view, and asks the model for the next page near its end.
 */

import type { MessageID, UserID } from "@inline/ids"
import { computed, effect, signal, untracked, type Dispose, type ReadSignal } from "@inline/reactive"
import type { Platform } from "@inline/view"
import type { FindHit, FindInChatModel } from "./find-model"
import { findKeyAction, findListMetrics, formatFindDate, listWindow, revealRow, snippetRuns, type ListWindow, type TextRun } from "./present"

export type FindSender = {
  readonly name: string
  /** Avatar color seed (`avatarSeed`); defaults to the name. */
  readonly seed?: string
  readonly photoUrl?: string
}

export type FindBarControllerOptions = {
  readonly model: FindInChatModel
  readonly platform: Platform
  /**
   * The sender of a match, for its preview. TODO(contract): `findInChat`
   * hits carry `fromId` only, and the sender's user row may not be on the
   * device's view store for an old message; default "You" for outgoing
   * messages, else "Unknown".
   */
  readonly sender?: (fromId: UserID, out: boolean) => FindSender
  /** Wall clock in milliseconds, for preview dates. */
  readonly now?: () => number
}

/** What a preview row shows, prepared once per hit. */
export type FindRowPresentation = {
  readonly sender: FindSender
  readonly date: string
  readonly snippet: readonly TextRun[]
}

type Part = { attach(element: HTMLElement): Dispose }

let nextId = 1

const defaultSender = (_fromId: UserID, out: boolean): FindSender => ({ name: out ? "You" : "Unknown" })

export class FindBarController {
  readonly model: FindInChatModel
  readonly platform: Platform
  readonly listId: string
  readonly #sender: (fromId: UserID, out: boolean) => FindSender
  readonly #now: () => number
  readonly #scrollTop = signal(0)
  readonly #viewport = signal<number>(findListMetrics.rowHeight * findListMetrics.maxVisibleRows)
  readonly #active = new Map<MessageID, ReadSignal<boolean>>()
  readonly #presentations = new WeakMap<FindHit, FindRowPresentation>()
  #composing = false
  #listElement: HTMLElement | null = null

  /** The rows to render. */
  readonly window: ReadSignal<ListWindow>

  readonly input: Part
  readonly list: Part

  constructor(options: FindBarControllerOptions) {
    this.model = options.model
    this.platform = options.platform
    this.listId = `find-${nextId++}-list`
    this.#sender = options.sender ?? defaultSender
    this.#now = options.now ?? Date.now
    this.window = computed(
      () => listWindow({ scrollTop: this.#scrollTop.get(), viewportHeight: this.#viewport.get(), count: this.model.hits.get().length }),
      { equals: (a, b) => a.start === b.start && a.end === b.end && a.before === b.before && a.after === b.after },
    )
    // Row signals are per query: drop the previous query's (rows still holding one keep working).
    effect(() => {
      this.model.query.get()
      untracked(() => this.#active.clear())
    })
    this.input = { attach: (element) => this.#attachInput(element as HTMLInputElement) }
    this.list = { attach: (element) => this.#attachList(element) }
  }

  /** The DOM ID of a preview row. */
  optionId(messageId: MessageID): string {
    return `${this.listId}-${messageId}`
  }

  /** Whether a row is the current match (one signal per row: moving renders two rows). */
  isActive(messageId: MessageID): ReadSignal<boolean> {
    let active = this.#active.get(messageId)
    if (!active) {
      active = computed(() => this.model.current.get()?.messageId === messageId)
      this.#active.set(messageId, active)
    }
    return active
  }

  /** Sender, date and snippet runs of a match, prepared once per hit object. */
  present(hit: FindHit): FindRowPresentation {
    let presentation = this.#presentations.get(hit)
    if (!presentation) {
      presentation = {
        sender: this.#sender(hit.fromId, hit.out),
        date: formatFindDate(hit.date, this.#now()),
        snippet: snippetRuns(hit.text, hit.ranges),
      }
      this.#presentations.set(hit, presentation)
    }
    return presentation
  }

  /** A key in the field. Returns whether it was handled (and prevented). */
  handleKeyDown(event: KeyboardEvent): boolean {
    if (event.defaultPrevented || this.#composing) return false
    const action = findKeyAction(event, { showsResults: this.model.showsResults.peek() })
    if (!action) return false
    event.preventDefault()
    switch (action) {
      case "close":
        this.model.close()
        break
      case "submit":
        this.model.submit()
        break
      case "next":
        this.model.next()
        break
      case "previous":
        this.model.previous()
        break
      case "moveNewer":
        this.model.moveActive(-1)
        break
      case "moveOlder":
        this.model.moveActive(1)
        break
    }
    return true
  }

  /** A key anywhere in the bar that the field did not handle (focus on a button): Escape closes. */
  barKeyDown(event: { readonly key: string; readonly defaultPrevented: boolean; readonly nativeEvent?: { readonly isComposing?: boolean }; preventDefault(): void }): void {
    if (event.defaultPrevented || event.nativeEvent?.isComposing === true || event.key !== "Escape") return
    event.preventDefault()
    this.model.close()
  }

  /** A press on a row: keep focus in the field. */
  rowPointerDown(event: { preventDefault(): void; button?: number }): void {
    if ((event.button ?? 0) === 0) event.preventDefault()
  }

  /** A click on a row. */
  rowClick(hit: FindHit): void {
    this.model.activate(hit)
  }

  /** Created inside `useModel`'s scope, so the constructor's effect is disposed with it. */
  dispose(): void {
    this.#active.clear()
    this.#listElement = null
  }

  #attachInput(element: HTMLInputElement): Dispose {
    const model = this.model
    element.setAttribute("role", "combobox")
    element.setAttribute("aria-autocomplete", "list")
    element.setAttribute("aria-controls", this.listId)
    element.setAttribute("autocomplete", "off")
    element.spellcheck = false

    const onInput = () => {
      if (!this.#composing) model.setText(element.value)
    }
    const onCompositionStart = () => {
      this.#composing = true
    }
    const onCompositionEnd = () => {
      this.#composing = false
      model.setText(element.value)
    }
    const onKeyDown = (event: KeyboardEvent) => {
      this.handleKeyDown(event)
    }
    const onFocus = () => model.setFieldFocused(true)
    const onBlur = () => model.setFieldFocused(false)
    element.addEventListener("input", onInput)
    element.addEventListener("compositionstart", onCompositionStart)
    element.addEventListener("compositionend", onCompositionEnd)
    element.addEventListener("keydown", onKeyDown)
    element.addEventListener("focus", onFocus)
    element.addEventListener("blur", onBlur)

    const stops = [
      effect(() => {
        const text = model.text.get()
        if (!this.#composing && element.value !== text) element.value = text
      }),
      effect(() => {
        const expanded = model.showsResults.get() && model.state.get() !== "idle"
        element.setAttribute("aria-expanded", expanded ? "true" : "false")
        const current = model.current.get()
        if (expanded && current) element.setAttribute("aria-activedescendant", this.optionId(current.messageId))
        else element.removeAttribute("aria-activedescendant")
      }),
      effect(() => {
        model.focusRequest.get()
        untracked(() => {
          if (element.ownerDocument.activeElement !== element) element.focus({ preventScroll: true })
          element.select()
          model.setFieldFocused(element.ownerDocument.activeElement === element)
        })
      }),
    ]
    return () => {
      for (const stop of stops) stop()
      element.removeEventListener("input", onInput)
      element.removeEventListener("compositionstart", onCompositionStart)
      element.removeEventListener("compositionend", onCompositionEnd)
      element.removeEventListener("keydown", onKeyDown)
      element.removeEventListener("focus", onFocus)
      element.removeEventListener("blur", onBlur)
      this.#composing = false
    }
  }

  #attachList(element: HTMLElement): Dispose {
    const model = this.model
    this.#listElement = element
    element.id = this.listId
    element.setAttribute("role", "listbox")
    element.setAttribute("aria-label", "Matches")

    const measure = () => {
      const height = element.clientHeight
      if (height > 0) this.#viewport.set(height)
    }
    const onScroll = () => {
      this.#scrollTop.set(element.scrollTop)
      model.loadMoreIfNeeded(this.window.peek().end - 1)
    }
    element.addEventListener("scroll", onScroll, { passive: true })
    const resize = typeof ResizeObserver === "function" ? new ResizeObserver(measure) : undefined
    resize?.observe(element)
    measure()
    this.#scrollTop.set(element.scrollTop)

    const stops = [
      // Keep the current row in view as the keyboard (or a page arriving) moves it.
      effect(() => {
        const index = model.currentIndex.get()
        if (index === undefined) return
        untracked(() => {
          const scrollTop = element.scrollTop
          const target = revealRow({ index, scrollTop, viewportHeight: element.clientHeight || this.#viewport.peek() })
          if (target === undefined) return
          element.scrollTop = target
          this.#scrollTop.set(element.scrollTop)
          model.loadMoreIfNeeded(this.window.peek().end - 1)
        })
      }),
      // A new query starts at the top.
      effect(() => {
        model.query.get()
        untracked(() => {
          if (element.scrollTop !== 0) element.scrollTop = 0
          this.#scrollTop.set(0)
        })
      }),
    ]
    return () => {
      for (const stop of stops) stop()
      element.removeEventListener("scroll", onScroll)
      resize?.disconnect()
      if (this.#listElement === element) this.#listElement = null
    }
  }
}
