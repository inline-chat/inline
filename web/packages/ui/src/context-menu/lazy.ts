/**
 * A context menu whose code loads on first use. Rows bind "open a context
 * menu here" with `target` (the small `ContextMenuTrigger`); the menu itself
 * (`MenuController`, `ContextMenuController` and the view) is the menu kit
 * chunk, loaded on the first request or earlier by `warm()` /
 * `loadMenuKit()` on the idle lane.
 *
 * A request made before the chunk arrives is never lost and never falls
 * through to the browser's menu: the trigger prevents the browser's menu at
 * once, and the menu opens when the chunk arrives, at the position and with
 * the focus return it would have had. A later request replaces an earlier
 * one still waiting; `close()` and `dispose()` drop it.
 *
 * Framework-free. The view half is `LazyMenuContent` in `@inline/ui/react`.
 */

import { computed, type ReadSignal, signal } from "@inline/reactive"
import type { Rect } from "../foundations/dom"
import type { Lazy } from "../foundations/lazy"
import type { Part } from "../foundations/parts"
import type { ContextMenuController, ContextMenuOptions } from "./controller"
import { menuKit, type MenuKitCore } from "./kit"
import { type ContextMenuInvocation, ContextMenuTrigger } from "./trigger"

/** Where the kit comes from: `menuKit`, or a `Lazy` of a test's own. */
export type MenuKitSource = Pick<Lazy<MenuKitCore>, "peek" | "load">

export type LazyContextMenuOptions = ContextMenuOptions & {
  /** The kit to load. Default the shared menu kit chunk (`menuKit`); tests pass their own. */
  kit?: MenuKitSource
  /** A load failed: the request is dropped (the browser's menu was already prevented). */
  onLoadError?: (error: unknown) => void
}

export class LazyContextMenu {
  readonly #options: LazyContextMenuOptions
  readonly #kit: MenuKitSource
  readonly #trigger: ContextMenuTrigger
  readonly #controller = signal<ContextMenuController | undefined>(undefined)
  #pending: ContextMenuInvocation | null = null
  #disposed = false

  /** The real controller, once the kit has loaded and a menu was requested (or warmed). */
  readonly controller: ReadSignal<ContextMenuController | undefined> = this.#controller
  /** True while the menu is open; false while its code is loading. */
  readonly isOpen: ReadSignal<boolean>
  /** True while a request waits for the kit. */
  readonly waiting = signal(false)

  constructor(options: LazyContextMenuOptions) {
    this.#options = options
    this.#kit = options.kit ?? menuKit
    this.#trigger = new ContextMenuTrigger({
      ...(options.shouldOpen ? { shouldOpen: options.shouldOpen } : {}),
      onInvoke: (invocation) => this.openFor(invocation),
    })
    this.isOpen = computed(() => this.#controller.get()?.menu.isOpen.get() ?? false)
  }

  /** Attach to the region whose secondary click opens the menu. */
  get target(): Part {
    return this.#trigger.target
  }

  /** Open for a captured request; synchronous when the kit is already here. */
  openFor(invocation: ContextMenuInvocation): void {
    if (this.#disposed) return
    const ready = this.#ensureController()
    if (ready) {
      ready.openFor(invocation)
      return
    }
    this.#pending = invocation
    this.waiting.set(true)
    void this.#kit.load().then(
      () => {
        const request = this.#pending
        this.#pending = null
        this.waiting.set(false)
        if (!request || this.#disposed) return
        this.#ensureController()?.openFor(request)
      },
      (error: unknown) => {
        this.#pending = null
        this.waiting.set(false)
        this.#options.onLoadError?.(error)
      },
    )
  }

  /** Open at a rectangle (a "More" button), as from the keyboard when `keyboard` is set. */
  openAt(anchor: Rect, options: { keyboard?: boolean; returnFocus?: HTMLElement | null } = {}): void {
    // No DOM (a test in Node): nothing has focus.
    const doc = typeof document === "undefined" ? null : document
    const active = doc?.activeElement ?? null
    const focused = doc && active && active !== doc.body && "focus" in active ? (active as HTMLElement) : null
    this.openFor({
      anchor,
      keyboard: options.keyboard ?? false,
      target: active,
      returnFocus: options.returnFocus !== undefined ? options.returnFocus : focused,
    })
  }

  /** Close the menu, or drop a request still waiting for the kit. */
  close(options: { restoreFocus?: boolean } = {}): void {
    if (this.#pending) {
      this.#pending = null
      this.waiting.set(false)
    }
    this.#controller.peek()?.menu.close(options)
  }

  /** Load the kit now (the idle lane), so the first request opens synchronously. */
  warm(): Promise<void> {
    return this.#kit.load().then(() => {
      this.#ensureController()
    })
  }

  #ensureController(): ContextMenuController | undefined {
    const existing = this.#controller.peek()
    if (existing) return existing
    const kit = this.#kit.peek()
    if (!kit || this.#disposed) return undefined
    const { kit: _kit, onLoadError: _onLoadError, ...options } = this.#options
    const controller = new kit.ContextMenuController(options)
    this.#controller.set(controller)
    return controller
  }

  dispose(): void {
    this.#disposed = true
    this.#pending = null
    this.#controller.peek()?.dispose()
  }
}
