/**
 * ContextMenu: a menu opened by secondary click, the context menu key, or
 * Shift+F10, anchored at the pointer (or at the target for keyboard opening).
 * Capturing the request is `ContextMenuTrigger`'s job (`trigger.ts`), which
 * this controller uses for its `target` part; `LazyContextMenu` uses the same
 * trigger without importing this file.
 */

import type { Part } from "../foundations/parts"
import { MenuController, type MenuOptions } from "../menu/controller"
import { type ContextMenuInvocation, type ContextMenuRequestEvent, ContextMenuTrigger } from "./trigger"

export type ContextMenuOptions = MenuOptions & {
  /**
   * Return false to let the browser's own menu show (in editable text, for
   * example). Gets the `contextmenu` event, or the `keydown` of Shift+F10.
   * (Method syntax: a handler typed for `MouseEvent` alone still fits.)
   */
  shouldOpen?(event: ContextMenuRequestEvent): boolean
}

export class ContextMenuController {
  readonly menu: MenuController
  readonly #trigger: ContextMenuTrigger

  constructor(options: ContextMenuOptions) {
    this.menu = new MenuController({ placement: "bottom-start", offset: 2, ...options })
    this.#trigger = new ContextMenuTrigger({
      ...(options.shouldOpen ? { shouldOpen: options.shouldOpen } : {}),
      onInvoke: (invocation) => this.openFor(invocation),
    })
  }

  /** Open at a viewport point, as a secondary click does. */
  openAt(x: number, y: number, options: { highlight?: "first" | "none" } = {}): void {
    this.menu.close({ restoreFocus: false })
    this.menu.open({ anchor: { x, y, width: 0, height: 0 }, highlight: options.highlight ?? "none" })
  }

  /**
   * Open for a captured request: at the point for a pointer, at the target
   * with the first item highlighted for the keyboard; focus returns to what
   * had it when the request was made.
   */
  openFor(invocation: ContextMenuInvocation): void {
    this.menu.close({ restoreFocus: false })
    this.menu.open({
      anchor: invocation.anchor,
      highlight: invocation.keyboard ? "first" : "none",
      returnFocus: invocation.returnFocus,
    })
  }

  /** The region that responds to secondary click. */
  get target(): Part {
    return this.#trigger.target
  }

  get content(): Part {
    return this.menu.content
  }

  item(id: string): Part {
    return this.menu.item(id)
  }

  dispose(): void {
    this.menu.dispose()
  }
}
