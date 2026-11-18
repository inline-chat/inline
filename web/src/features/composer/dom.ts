/**
 * The few DOM facts the composer view needs that the composer package does
 * not expose: the on-screen rectangle of a model range (to anchor the
 * autocomplete at its trigger character) and whether an event target is an
 * editable field (type anywhere to focus). Browser-only; the logic that uses
 * them is tested through injected functions.
 */

import { offsetToDomPoint } from "@inline/composer"
import type { Rect } from "@inline/ui"

const toRect = (r: DOMRect | DOMRectReadOnly): Rect => ({ x: r.left, y: r.top, width: r.width, height: r.height })

export const elementRect = (element: Element): Rect => toRect(element.getBoundingClientRect())

/**
 * The rectangle of model offsets `[from, to)` inside a surface rendered by the
 * composer binding, or null if the range has no box (detached, or not laid
 * out). For a single character this is that character's box on its line.
 */
export const textRect = (root: HTMLElement, from: number, to: number): Rect | null => {
  const doc = root.ownerDocument
  const start = offsetToDomPoint(root, from)
  const end = offsetToDomPoint(root, Math.max(from, to))
  const range = doc.createRange()
  try {
    range.setStart(start.node, start.offset)
    range.setEnd(end.node, end.offset)
  } catch {
    return null
  }
  const rects = Array.from(range.getClientRects())
  // A boundary point at the end of the previous run yields an empty box first.
  const box = rects.find((r) => r.width > 0 && r.height > 0) ?? rects.find((r) => r.height > 0)
  if (box) return toRect(box)
  const bounds = range.getBoundingClientRect()
  return bounds.height > 0 ? toRect(bounds) : null
}

/** Keep an anchor inside the visible part of a scrolled surface, so the popup never points at hidden text. */
export const clampRect = (rect: Rect, within: Rect): Rect => {
  const y = Math.min(Math.max(rect.y, within.y), within.y + Math.max(0, within.height - rect.height))
  return { ...rect, y }
}

/** Inputs, text areas, selects and anything editable take typed characters themselves. */
export const isEditableTarget = (target: EventTarget | null): boolean => {
  if (!target || typeof (target as Element).closest !== "function") return false
  const element = target as HTMLElement
  if (element.isContentEditable) return true
  const tag = element.localName
  if (tag === "textarea" || tag === "select") return true
  if (tag === "input") {
    const type = (element as HTMLInputElement).type
    return !["button", "checkbox", "radio", "range", "color", "file", "image", "reset", "submit"].includes(type)
  }
  // Dialogs and menus own their keys.
  return element.closest("dialog, [role=menu], [role=listbox], [role=dialog], [role=combobox]") !== null
}
