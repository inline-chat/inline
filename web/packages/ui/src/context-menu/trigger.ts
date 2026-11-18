/**
 * The cheap half of a context menu: capturing the request. Attach `target`
 * to a region; a secondary click, the context menu key or Shift+F10 inside
 * it becomes a `ContextMenuInvocation` (where to anchor, whether it came from
 * the keyboard, where focus goes back), and the browser's own menu is
 * prevented at once. What opens is the caller's business: the real menu
 * (`ContextMenuController.openFor`), or `LazyContextMenu`, which loads the
 * menu's code first. No menu code is imported here.
 *
 * Long press on touch devices arrives as the platform's `contextmenu` event,
 * like a secondary click. Shift+F10 is also taken from `keydown`, because
 * some browsers (Chromium and Safari on macOS) fire no `contextmenu` for it;
 * where the platform fires one after our keydown, it is swallowed.
 */

import { activeElementOf, type Dispose, disposeAll, listen, type Rect, rectOf } from "../foundations/dom"
import type { Part } from "../foundations/parts"

export type ContextMenuInvocation = {
  /** A zero-size point for a pointer, the target's rectangle for the keyboard. */
  readonly anchor: Rect
  readonly keyboard: boolean
  /** Where the request happened (the event's target); null for a request made in code. */
  readonly target: Element | null
  /** What had focus when the menu was asked for: focus returns there when it closes. */
  readonly returnFocus: HTMLElement | null
}

/** A `contextmenu` event, or the `keydown` of Shift+F10 or the context menu key. */
export type ContextMenuRequestEvent = MouseEvent | KeyboardEvent

export type ContextMenuTriggerOptions = {
  /**
   * Return false to let the browser's own menu show (in editable text, for
   * example). Gets the `contextmenu` event, or the `keydown` of Shift+F10.
   * (Method syntax: a handler typed for `MouseEvent` alone still fits.)
   */
  shouldOpen?(event: ContextMenuRequestEvent): boolean
  /** Called once per request, after the browser's menu was prevented. */
  onInvoke: (invocation: ContextMenuInvocation) => void
}

export const isContextMenuKey = (event: Pick<KeyboardEvent, "key" | "shiftKey" | "ctrlKey" | "metaKey" | "altKey">): boolean =>
  (event.key === "F10" && event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey) || event.key === "ContextMenu"

const focusedElement = (doc: Document): HTMLElement | null => {
  const active = activeElementOf(doc)
  return active instanceof HTMLElement && active !== doc.body ? active : null
}

export class ContextMenuTrigger {
  readonly #options: ContextMenuTriggerOptions
  /** Set by a pointer press, cleared by a key press: tells pointer and keyboard requests apart. */
  #pointerPressed = false
  /** A keydown opened the menu; the platform's `contextmenu` for the same key is not a second request. */
  #keyboardOpened = false

  constructor(options: ContextMenuTriggerOptions) {
    this.#options = options
  }

  /** The region that responds to secondary click and the context menu keys. */
  readonly target: Part = {
    attach: (element) => {
      const invoke = (source: Element, keyboard: boolean, point?: { x: number; y: number }) => {
        this.#options.onInvoke({
          anchor: point ? { x: point.x, y: point.y, width: 0, height: 0 } : rectOf(source),
          keyboard,
          target: source,
          returnFocus: focusedElement(element.ownerDocument),
        })
      }
      const disposers: Dispose[] = [
        listen(
          element,
          "pointerdown",
          () => {
            this.#pointerPressed = true
            this.#keyboardOpened = false
          },
          true,
        ),
        listen(
          element,
          "keydown",
          (event: KeyboardEvent) => {
            this.#pointerPressed = false
            if (!isContextMenuKey(event)) this.#keyboardOpened = false
          },
          true,
        ),
        listen(element, "keydown", (event: KeyboardEvent) => {
          // Only Shift+F10 here: the context menu key always fires `contextmenu`.
          if (event.key !== "F10" || !isContextMenuKey(event) || event.defaultPrevented) return
          if (this.#options.shouldOpen && !this.#options.shouldOpen(event)) return
          event.preventDefault()
          this.#keyboardOpened = true
          invoke(event.target instanceof Element ? event.target : element, true)
        }),
        listen(element, "contextmenu", (event: MouseEvent) => {
          if (event.defaultPrevented) return
          const fromKeyboard = !this.#pointerPressed
          this.#pointerPressed = false
          if (fromKeyboard && this.#keyboardOpened) {
            this.#keyboardOpened = false
            event.preventDefault()
            return
          }
          if (this.#options.shouldOpen && !this.#options.shouldOpen(event)) return
          event.preventDefault()
          const source = event.target instanceof Element ? event.target : element
          if (fromKeyboard) invoke(source, true)
          else invoke(source, false, { x: event.clientX, y: event.clientY })
        }),
      ]
      return () => disposeAll(disposers)
    },
  }
}
