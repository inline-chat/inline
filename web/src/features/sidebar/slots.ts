/**
 * Row recycling. The list renders a fixed set of slots; each slot shows one
 * key of the window and keeps it while that key stays in the window. A key
 * that leaves frees its slot; a key that enters takes a free one. So:
 *
 * - scrolling re-renders only the slots whose key changed, reusing their DOM
 *   (text and attributes change; nothing mounts or unmounts);
 * - a reorder inside the window changes no slot, so no row renders (the
 *   controller moves the elements);
 * - the focused row's element never moves or remounts.
 *
 * DOM order is slot order, not list order; every option carries
 * `aria-posinset` and `aria-setsize`.
 */

import type { RowKey } from "@inline/core-protocol"

export type SlotKeys = readonly (RowKey | undefined)[]

/** Spare slots kept beyond the window before trailing empty slots are dropped. */
export const SLOT_SLACK = 16

/**
 * The next assignment for `window`, keeping every key that stays in its slot.
 * Returns `previous` itself when nothing changed.
 */
export const assignSlots = (previous: SlotKeys, window: readonly RowKey[], slack = SLOT_SLACK): SlotKeys => {
  const wanted = new Set(window)
  const next: (RowKey | undefined)[] = previous.map((key) => (key !== undefined && wanted.has(key) ? key : undefined))
  const placed = new Set<RowKey>()
  for (const key of next) if (key !== undefined) placed.add(key)
  let free = 0
  for (const key of window) {
    if (placed.has(key)) continue
    while (free < next.length && next[free] !== undefined) free++
    if (free < next.length) next[free] = key
    else next.push(key)
    placed.add(key)
  }
  // Drop trailing empty slots only when far more exist than the window needs.
  if (next.length > window.length + slack) {
    while (next.length > window.length && next[next.length - 1] === undefined) next.pop()
  }
  if (next.length === previous.length && next.every((key, index) => key === previous[index])) return previous
  return next
}

/** Keys of `next` that `previous` did not show: the slots that must render. */
export const enteringKeys = (previous: SlotKeys, next: SlotKeys): RowKey[] => {
  if (previous === next) return []
  const before = new Set(previous)
  const entering: RowKey[] = []
  for (const key of next) if (key !== undefined && !before.has(key)) entering.push(key)
  return entering
}
