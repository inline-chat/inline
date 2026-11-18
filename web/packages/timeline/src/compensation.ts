/**
 * Compensation from row heights. One owner corrects the scroll offset, by the
 * sum of the height changes above the reader's anchor row:
 *
 * - a batch of size changes: each row above the anchor contributes its new
 *   height minus its cached height;
 * - a structural change (rows inserted, removed or moved): each row that is
 *   now above the anchor and was not contributes its height, each row that
 *   was above and is not any more contributes minus its cached height.
 *
 * Working from heights rather than from the anchor's measured position keeps
 * the correction right even when an anchor was captured after the browser
 * had already laid out a pending resize (a scroll event between layout and
 * the resize observer), and every height change is counted exactly once
 * through the size cache. See the README ("Compensation").
 */

import type { ItemKey, RowSize } from "./host"

export type SizeCache = Map<ItemKey, number>

export const indexKeys = (keys: readonly ItemKey[]): Map<ItemKey, number> => {
  const index = new Map<ItemKey, number>()
  for (let i = 0; i < keys.length; i++) index.set(keys[i]!, i)
  return index
}

/** The first anchor that is rendered in both orders: the reader's reference row. */
export const survivingAnchor = (
  anchors: readonly ItemKey[],
  ...orders: ReadonlyMap<ItemKey, number>[]
): ItemKey | undefined => anchors.find((key) => orders.every((order) => order.has(key)))

/**
 * Sum of height changes above `anchor` from a resize batch, updating the
 * cache. Zero-size entries come from hidden elements (`display: none` on an
 * ancestor) and are ignored, cache included, so a row shown again at its old
 * size changes nothing. A row never measured counts from zero.
 */
export const resizeDelta = (
  rows: readonly RowSize[],
  order: ReadonlyMap<ItemKey, number>,
  anchor: ItemKey | undefined,
  sizes: SizeCache,
): number => {
  const anchorIndex = anchor === undefined ? undefined : order.get(anchor)
  let delta = 0
  for (const { key, height } of rows) {
    if (!(height > 0)) continue
    const index = order.get(key)
    if (index === undefined) continue
    const old = sizes.get(key) ?? 0
    sizes.set(key, height)
    if (anchorIndex !== undefined && index < anchorIndex) delta += height - old
  }
  return delta
}

/**
 * Sum of height changes above `anchor` from a change of rendered order. Call
 * after adding the new rows' heights to the cache and before deleting the
 * removed ones.
 */
export const structuralDelta = (
  before: readonly ItemKey[],
  beforeIndex: ReadonlyMap<ItemKey, number>,
  after: readonly ItemKey[],
  afterIndex: ReadonlyMap<ItemKey, number>,
  anchor: ItemKey,
  sizes: SizeCache,
): number => {
  const anchorBefore = beforeIndex.get(anchor)
  const anchorAfter = afterIndex.get(anchor)
  if (anchorBefore === undefined || anchorAfter === undefined) return 0
  let delta = 0
  for (let i = 0; i < anchorBefore; i++) {
    const key = before[i]!
    const now = afterIndex.get(key)
    if (now === undefined || now > anchorAfter) delta -= sizes.get(key) ?? 0
  }
  for (let i = 0; i < anchorAfter; i++) {
    const key = after[i]!
    const was = beforeIndex.get(key)
    if (was === undefined || was > anchorBefore) delta += sizes.get(key) ?? 0
  }
  return delta
}
