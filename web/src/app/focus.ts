/**
 * Keyboard and focus wiring for the window. Framework-free; touches the DOM
 * only when called.
 *
 * - One `keydown` listener on the window feeds the keyboard dispatcher (bubble
 *   phase, so a field that handled a key, such as the composer's Enter, has
 *   already called `preventDefault` and the dispatcher ignores it).
 * - Focus regions are marked in the markup with `data-focus-region`
 *   (`sidebar`, `timeline`, `composer`); a `focusin` listener tells the
 *   dispatcher which region has focus, so region-scoped commands (Escape in
 *   the message list) resolve.
 * - The focus guard: when the focused element is removed (a chat swapped
 *   out, a layer closed whose trigger is gone), focus would fall to `body`.
 *   The guard notices at the next frame and asks the shell to put it back.
 *   It never acts when focus moved to `body` because the user clicked
 *   somewhere unfocusable (the element is still connected), so a text
 *   selection in the timeline is never disturbed.
 */

import type { KeyEventLike } from "@inline/view"

export const FOCUS_REGION_ATTRIBUTE = "data-focus-region"

export type FocusRegionName = "sidebar" | "timeline" | "composer"

type ClosestLike = { closest?(selector: string): { getAttribute(name: string): string | null } | null }

/** The region a focus target is in, from the nearest `data-focus-region` ancestor. */
export const regionOf = (target: unknown): FocusRegionName | undefined => {
  const element = target as ClosestLike | null
  if (!element || typeof element.closest !== "function") return undefined
  const value = element.closest(`[${FOCUS_REGION_ATTRIBUTE}]`)?.getAttribute(FOCUS_REGION_ATTRIBUTE)
  return value === "sidebar" || value === "timeline" || value === "composer" ? value : undefined
}

export type KeyboardLike = {
  handleKeyDown(event: KeyEventLike): unknown
  setFocusScopes(scopes: readonly string[]): void
}

/** Bind the window's keyboard and focus regions. Returns the unbind function. */
export const bindWindowKeyboard = (win: Window, keyboard: KeyboardLike): (() => void) => {
  const onKeyDown = (event: KeyboardEvent) => {
    keyboard.handleKeyDown(event)
  }
  const onFocusIn = (event: FocusEvent) => {
    const region = regionOf(event.target)
    keyboard.setFocusScopes(region ? [region] : [])
  }
  win.addEventListener("keydown", onKeyDown)
  win.document.addEventListener("focusin", onFocusIn)
  return () => {
    win.removeEventListener("keydown", onKeyDown)
    win.document.removeEventListener("focusin", onFocusIn)
  }
}

/** Watches for focus lost to a removed element. Returns the unbind function. */
export const bindFocusGuard = (win: Window, restore: () => void): (() => void) => {
  const doc = win.document
  let scheduled = false
  const onFocusOut = (event: FocusEvent) => {
    const left = event.target as Node | null
    if (event.relatedTarget !== null || !left || scheduled) return
    scheduled = true
    win.requestAnimationFrame(() => {
      scheduled = false
      const active = doc.activeElement
      const lost = active === null || active === doc.body
      if (lost && !left.isConnected && doc.hasFocus()) restore()
    })
  }
  doc.addEventListener("focusout", onFocusOut)
  return () => doc.removeEventListener("focusout", onFocusOut)
}

/** Focus an element without scrolling the page (`timeline-and-composer.md`, "Feel"). */
export const focusWithoutScroll = (element: HTMLElement | null | undefined): boolean => {
  if (!element) return false
  element.focus({ preventScroll: true })
  return element.ownerDocument.activeElement === element
}
