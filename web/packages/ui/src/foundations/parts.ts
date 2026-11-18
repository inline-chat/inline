/**
 * A part is anything a view hands an element to: `attach(element)` wires it
 * and returns the cleanup. Views pass parts to `useElement` (React) or `ref`
 * (Solid). Parts are cached by their controllers so their identity is stable.
 */

import type { Dispose } from "./dom"

export interface Part {
  attach(element: HTMLElement): Dispose
}

/** One part that attaches several to the same element (a menu trigger with a tooltip). */
export const combineParts = (...parts: Part[]): Part => ({
  attach(element) {
    const disposers = parts.map((part) => part.attach(element))
    return () => {
      for (let index = disposers.length - 1; index >= 0; index--) disposers[index]?.()
    }
  },
})
