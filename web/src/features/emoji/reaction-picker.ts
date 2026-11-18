/**
 * The reaction picker: what a message's "Add Reaction" opens. A row of quick
 * reactions with a button that expands to the full picker, in one popover.
 * Framework-free; `ReactionPicker.tsx` renders it.
 *
 * - The row is the Mac's (`ReactionOverlayView.swift`): the message's own
 *   emoji first, then the user's most picked reactions, then the default
 *   set, 15 in all, in the preferred skin tone; built when the picker opens.
 *   A reaction the viewer already added shows as pressed, and choosing it
 *   removes it (the caller toggles).
 * - Keys in the row: Left and Right (following the writing direction), Home
 *   and End move; Return or Space chooses; Down, or the plus button, opens
 *   the full picker; typing a letter opens it searching for that letter;
 *   Delete removes a learned suggestion ("Remove from suggestions" in the
 *   context menu on the Mac). Escape closes, through the popover.
 * - Choosing records the pick (for the row and for frecency) only when it
 *   adds a reaction, as the Mac does.
 *
 * The popover is the caller's (the chat feature's `MessageActions.picker`
 * already anchors one at the button or the row) or the controller's own.
 *
 * Focus: the kit's popover moves focus to the first tab stop when it
 * opens, which is the row's active button. On the first frame after any
 * open (the caller's popover too) the controller hands focus to the active
 * button again if it is not in the row, so a view that renders the row
 * after the open (a new row for a new message) still ends with the row
 * focused. The controller's own popover waits for its anchor to be laid
 * out before it opens (`openWhenAnchored`), and on close returns focus to
 * the anchor when the opener did not hold it (a click that does not focus
 * buttons, a call from code).
 */

import { computed, effect, signal, untracked, type Dispose, type ReadSignal, type Signal } from "@inline/reactive"
import { ContextMenuController, directionOf, PopoverController, type MenuEntry, type Rect } from "@inline/ui"
import type { EmojiInfo } from "./engine"
import { focusable, type FrameScheduler, nextFrame, openWhenAnchored } from "./frame"
import { EmojiPickerController, type KeyInput } from "./picker"
import { quickRow, type QuickReaction } from "./quick"
import type { EmojiServices } from "./services"

export type ReactionPickerTarget = {
  /** The message's text, for its own emoji. */
  readonly messageText?: string | null
  /** Emoji the viewer already reacted with. */
  readonly mine?: Iterable<string>
}

export type ReactionPickerOptions = {
  readonly services: EmojiServices
  /** A reaction was chosen: add it, or remove it when `mine`. The picker closes after this runs. */
  readonly onChoose: (emoji: string, mine: boolean) => void
  /** The popover to live in. Default: a new one placed above the anchor. */
  readonly popover?: PopoverController
  /** Where the popover anchors when the controller opens it itself. */
  readonly anchor?: () => Element | Rect | null
  readonly direction?: () => "ltr" | "rtl"
  /**
   * The message the caller opened the picker for, as a signal (the chat
   * feature's `MessageActions.pickerTarget`). Each new value prepares the
   * row; updates to the same value do not, so the row holds while open.
   */
  readonly target?: ReadSignal<unknown>
  /** What `prepare` needs from a `target` value. */
  readonly describe?: (target: unknown) => ReactionPickerTarget
  /** The next frame (focus hand-off, waiting for the anchor). Default `requestAnimationFrame`. */
  readonly frame?: FrameScheduler
}

export type ReactionPickerMode = "quick" | "full"

export class ReactionPickerController {
  readonly popover: PopoverController
  readonly mode: ReadSignal<ReactionPickerMode>
  /** The quick row, built on `prepare`. */
  readonly quick: ReadSignal<readonly QuickReaction[]>
  /** The quick row's keyboard position; `quick.length` is the expand button. */
  readonly focusIndex: ReadSignal<number>
  /** The full picker, once expanded and the emoji data has loaded. */
  readonly full: ReadSignal<EmojiPickerController | undefined>
  /** Expanded, waiting for the emoji data. */
  readonly loading: ReadSignal<boolean>

  readonly #options: ReactionPickerOptions
  readonly #mode = signal<ReactionPickerMode>("quick")
  readonly #target = signal<{ text: string | null; mine: ReadonlySet<string> }>({ text: null, mine: new Set() })
  readonly #focusIndex = signal(0)
  readonly #full = signal<EmojiPickerController | undefined>(undefined)
  readonly #pendingQuery: Signal<string | null> = signal<string | null>(null)
  readonly #counts = signal<ReadonlyMap<string, number>>(new Map())
  readonly #ownsPopover: boolean
  readonly #menuTarget = signal<string | undefined>(undefined)

  /**
   * "Remove from Suggestions" on a learned quick reaction (secondary click,
   * the context menu key or Shift+F10), as on the Mac. Other buttons keep no menu.
   */
  readonly suggestionMenu: ContextMenuController
  #rowElement: HTMLElement | null = null
  readonly #stops: Dispose[] = []
  readonly #frame: FrameScheduler
  #cancelOpen: Dispose | null = null
  /** Bumped on every open and on dispose; a hand-off for an older open does nothing. */
  #handOff = 0

  constructor(options: ReactionPickerOptions) {
    this.#options = options
    this.#ownsPopover = !options.popover
    this.#frame = options.frame ?? nextFrame
    this.popover =
      options.popover ??
      new PopoverController({
        placement: "top-start",
        offset: 6,
        role: "dialog",
        label: "Add reaction",
        ...(options.anchor ? { anchor: options.anchor } : {}),
        onOpenChange: (open) => {
          if (!open) this.#returnFocusToAnchor()
        },
      })
    this.mode = this.#mode
    this.focusIndex = this.#focusIndex
    this.suggestionMenu = new ContextMenuController({
      label: "Reaction",
      items: (): readonly MenuEntry[] => {
        const emoji = this.#menuTarget.get()
        if (!emoji) return []
        return [{ type: "item", id: "remove", label: "Remove from Suggestions", destructive: true, onSelect: () => this.removeSuggestion(emoji) }]
      },
      shouldOpen: (event) => {
        const button = event.target instanceof Element ? event.target.closest("[data-quick-index]") : null
        const item = this.quick.peek()[Number(button?.getAttribute("data-quick-index"))]
        if (!item?.removable) {
          // Nothing to offer: no menu, and not the browser's either.
          event.preventDefault()
          return false
        }
        this.#menuTarget.set(item.emoji)
        return true
      },
    })
    this.full = this.#full
    const { usage, loader, support } = options.services

    this.quick = computed(() => {
      const engine = loader.engine.get()
      const target = this.#target.get()
      return quickRow({
        counts: this.#counts.get(),
        messageText: target.text,
        tone: usage.skinTone.get(),
        mine: target.mine,
        // Checked now (a few canvas draws, kept for the page's life): the
        // row skips what this platform cannot draw and takes the next one.
        supported: (emoji: string) => support.check(emoji),
        ...(engine ? { toneTemplate: (emoji: string) => engine.lookup(emoji)?.tone } : {}),
      })
    })

    // Focus hand-off on the first frame after an open, whoever opened it.
    this.#stops.push(
      effect(() => {
        if (!this.popover.isOpen.get()) return
        untracked(() => {
          const token = ++this.#handOff
          this.#frame(() => {
            if (token === this.#handOff) this.#focusRowIfLost()
          })
        })
      }),
    )
    this.loading = computed(() => this.#mode.get() === "full" && !this.#full.get())

    if (options.target) {
      const target = options.target
      let last: unknown
      this.#stops.push(
        effect(() => {
          const value = target.get()
          untracked(() => {
            if (value === undefined || value === null || value === last) {
              last = value
              return
            }
            last = value
            this.prepare(options.describe ? options.describe(value) : (value as ReactionPickerTarget))
          })
        }),
      )
    }

    // Expanded before the data arrived: build the picker when it does.
    this.#stops.push(
      effect(() => {
        const engine = loader.engine.get()
        const query = this.#pendingQuery.get()
        if (!engine || query === null) return
        untracked(() => {
          this.#pendingQuery.set(null)
          this.#buildFull(query)
        })
      }),
    )
  }

  /** Fill the row for a message. Call when the picker opens (the popover's open). */
  prepare(target: ReactionPickerTarget = {}): void {
    this.#counts.set(this.#options.services.usage.reactionCounts())
    this.#target.set({ text: target.messageText ?? null, mine: new Set(target.mine ?? []) })
    this.#mode.set("quick")
    this.#pendingQuery.set(null)
    this.#focusIndex.set(0)
    this.#full.peek()?.dispose()
    this.#full.set(undefined)
    // Warm the data so the full picker opens at once.
    void this.#options.services.loader.load().catch(() => undefined)
  }

  /**
   * Prepare and open the controller's own popover (or the given one). With
   * an `anchor`, the open waits for it to be laid out (a frame at a time),
   * so a picker opened in code at start-up is placed like any other.
   */
  open(target: ReactionPickerTarget = {}): void {
    this.prepare(target)
    this.#cancelOpen?.()
    this.#cancelOpen = null
    const anchor = this.#options.anchor
    if (!this.#ownsPopover || !anchor) {
      this.popover.open()
      return
    }
    this.#cancelOpen = openWhenAnchored(
      anchor,
      () => {
        this.#cancelOpen = null
        this.popover.open()
      },
      this.#frame,
    )
  }

  close(): void {
    this.#cancelOpen?.()
    this.#cancelOpen = null
    this.popover.close()
  }

  /** The popover's content element, while it is in the document. */
  #content(): HTMLElement | null {
    const doc = this.#rowElement?.ownerDocument ?? globalThis.document
    return doc?.getElementById(this.popover.id) ?? null
  }

  /**
   * Put focus on the active quick button when it is not in the row and
   * nothing else took it: lost (the document's body), still on the opener,
   * or elsewhere in the popover.
   */
  #focusRowIfLost(): void {
    if (!this.popover.isOpen.peek() || this.#mode.peek() !== "quick") return
    const row = this.#rowElement
    if (!row?.isConnected) return
    const doc = row.ownerDocument
    const active = doc.activeElement
    if (active && row.contains(active)) return
    const opener = focusable(this.#options.anchor?.())
    const lost = !active || active === doc.body || active === opener || (this.#content()?.contains(active) ?? false)
    if (lost) this.#focusCurrent()
  }

  /** The own popover closed: back to the anchor if focus was left nowhere (or in the closed popover). */
  #returnFocusToAnchor(): void {
    const anchor = focusable(this.#options.anchor?.())
    if (!anchor) return
    const doc = anchor.ownerDocument
    const active = doc.activeElement
    if (!active || active === doc.body || (this.#content()?.contains(active) ?? false)) anchor.focus({ preventScroll: true })
  }

  /** Show the full picker, optionally searching. */
  expand(query = ""): void {
    this.#mode.set("full")
    const engine = this.#options.services.loader.engine.peek()
    if (engine) this.#buildFull(query)
    else {
      this.#pendingQuery.set(query)
      void this.#options.services.loader.load().catch(() => undefined)
    }
  }

  #buildFull(query: string): void {
    const engine = this.#options.services.loader.engine.peek()
    if (!engine) return
    this.#full.peek()?.dispose()
    this.#full.set(
      new EmojiPickerController({
        engine,
        usage: this.#options.services.usage,
        support: this.#options.services.support,
        initialQuery: query,
        onChoose: (emoji) => this.choose(emoji),
        ...(this.#options.direction ? { direction: this.#options.direction } : {}),
      }),
    )
  }

  /**
   * Choose a reaction. Adding one records it; removing one does not. The
   * caller's `onChoose` runs while the popover is still open (so a caller
   * that reads its own open state, such as `MessageActions.choose`, still
   * has its target), then the popover closes if the caller did not.
   */
  choose(emoji: string, _info?: EmojiInfo): void {
    const mine = this.#target.peek().mine.has(emoji)
    if (!mine) this.#options.services.usage.recordReaction(emoji)
    this.#options.onChoose(emoji, mine)
    this.popover.close()
  }

  /** "Remove from suggestions" for a learned quick reaction. */
  removeSuggestion(emoji: string): void {
    const item = this.quick.peek().find((candidate) => candidate.emoji === emoji)
    if (!item?.removable) return
    this.#options.services.usage.removeReactionSuggestion(item.source)
    this.#counts.set(this.#options.services.usage.reactionCounts())
    this.#focusIndex.set(Math.min(this.#focusIndex.peek(), this.quick.peek().length))
    this.#focusCurrent()
  }

  /** Keys in the quick row. Returns true when used. */
  handleQuickKey(input: KeyInput): boolean {
    if (input.isComposing || this.#mode.peek() !== "quick") return false
    const items = this.quick.peek()
    const last = items.length // the expand button
    const index = this.#focusIndex.peek()
    const rtl = this.#direction() === "rtl"
    const moveTo = (next: number) => {
      this.#focusIndex.set(Math.max(0, Math.min(last, next)))
      this.#focusCurrent()
      return true
    }
    switch (input.key) {
      case "ArrowRight":
        return moveTo(index + (rtl ? -1 : 1))
      case "ArrowLeft":
        return moveTo(index + (rtl ? 1 : -1))
      case "Home":
        return moveTo(0)
      case "End":
        return moveTo(last)
      case "ArrowDown":
        this.expand()
        return true
      case "Enter":
      case " ": {
        if (index === last) this.expand()
        else {
          const item = items[index]
          if (item) this.choose(item.emoji)
        }
        return true
      }
      case "Delete":
      case "Backspace": {
        const item = items[index]
        if (item?.removable) {
          this.removeSuggestion(item.emoji)
          return true
        }
        return false
      }
      default:
        break
    }
    if (input.key.length === 1 && !input.ctrlKey && !input.metaKey && !input.altKey && input.key.trim() !== "") {
      this.expand(input.key)
      return true
    }
    return false
  }

  #direction(): "ltr" | "rtl" {
    if (this.#options.direction) return this.#options.direction()
    return directionOf(this.#rowElement)
  }

  #focusCurrent(): void {
    const element = this.#rowElement
    if (!element) return
    const buttons = element.querySelectorAll<HTMLElement>("[data-quick-index]")
    buttons[this.#focusIndex.peek()]?.focus({ preventScroll: false })
  }

  /** The quick row's container: keys, and focus moving with the roving index. */
  readonly row = {
    attach: (element: HTMLElement): Dispose => {
      this.#rowElement = element
      element.setAttribute("role", "toolbar")
      element.setAttribute("aria-label", "Quick reactions")
      const onKeyDown = (event: KeyboardEvent) => {
        if (this.handleQuickKey(event)) {
          event.preventDefault()
          event.stopPropagation()
        }
      }
      const onFocusIn = (event: FocusEvent) => {
        const target = event.target instanceof Element ? event.target.closest("[data-quick-index]") : null
        const index = Number(target?.getAttribute("data-quick-index"))
        if (Number.isInteger(index)) this.#focusIndex.set(index)
      }
      element.addEventListener("keydown", onKeyDown)
      element.addEventListener("focusin", onFocusIn)
      return () => {
        element.removeEventListener("keydown", onKeyDown)
        element.removeEventListener("focusin", onFocusIn)
        if (this.#rowElement === element) this.#rowElement = null
      }
    },
  }

  dispose(): void {
    this.#cancelOpen?.()
    this.#cancelOpen = null
    this.#handOff += 1
    for (const stop of this.#stops.splice(0)) stop()
    this.#full.peek()?.dispose()
    this.#full.set(undefined)
    this.suggestionMenu.menu.close({ restoreFocus: false })
    if (this.#ownsPopover) this.popover.dispose()
  }
}
