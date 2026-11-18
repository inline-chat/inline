/**
 * Stable identity for streaming.
 *
 * Agent messages are edited in place many times a second, mostly by appending.
 * Node keys come from a node's kind and start offset, so appending text never
 * changes the key of an earlier node. `reuseUnchanged` goes further and gives
 * back the previous object for every node that is structurally equal, so a
 * view that compares by identity (React `memo`, a keyed list) touches only the
 * node that changed: usually the last run of the last paragraph.
 */

import { buildTextDocument, type TextRenderOptions } from "./build"
import type { TextDocument } from "./types"

type Keyed = { readonly key: string }

const isKeyed = (value: unknown): value is Keyed =>
  typeof value === "object" && value !== null && typeof (value as { key?: unknown }).key === "string"

const isPlainObject = (value: unknown): value is Record<string, unknown> => {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false
  const proto: unknown = Object.getPrototypeOf(value)
  return proto === Object.prototype || proto === null
}

/**
 * `next`, with every part that is structurally equal to the matching part of
 * `prev` replaced by `prev`'s object. Arrays of keyed nodes match by key,
 * other arrays by index. Returns `prev` itself when nothing changed.
 */
export const reuseUnchanged = <T>(prev: T, next: T): T => {
  if (Object.is(prev, next)) return prev
  if (Array.isArray(prev) && Array.isArray(next)) return reuseArray(prev, next) as T
  if (isPlainObject(prev) && isPlainObject(next)) return reuseObject(prev, next) as T
  return next
}

const reuseArray = (prev: readonly unknown[], next: readonly unknown[]): readonly unknown[] => {
  let byKey: Map<string, unknown> | undefined
  if (next.length > 0 && isKeyed(next[0])) {
    byKey = new Map()
    for (const item of prev) if (isKeyed(item)) byKey.set(item.key, item)
  }
  let same = prev.length === next.length
  const out = next.map((item, index) => {
    const match = byKey && isKeyed(item) ? byKey.get(item.key) : prev[index]
    const reused = match === undefined ? item : reuseUnchanged(match, item)
    if (reused !== prev[index]) same = false
    return reused
  })
  return same ? prev : out
}

const reuseObject = (prev: Record<string, unknown>, next: Record<string, unknown>): Record<string, unknown> => {
  const keys = Object.keys(next)
  let same = keys.length === Object.keys(prev).length
  const out: Record<string, unknown> = {}
  for (const key of keys) {
    const reused = key in prev ? reuseUnchanged(prev[key], next[key]) : next[key]
    if (reused !== prev[key]) same = false
    out[key] = reused
  }
  return same ? prev : out
}

const sourceEntities = new WeakMap<TextDocument, unknown>()

/**
 * Builds the document for `text` and `entities`, reusing every unchanged node
 * of `prev`. Returns `prev` when the input is the same text and the same
 * entities array. This is what a row view model calls on each message update.
 */
export const updateTextDocument = (
  prev: TextDocument | undefined,
  text: unknown,
  entities?: unknown,
  options?: TextRenderOptions,
): TextDocument => {
  if (prev && prev.text === text && sourceEntities.has(prev) && sourceEntities.get(prev) === entities) return prev
  const built = buildTextDocument(text, entities, options)
  const next = prev ? reuseUnchanged(prev, built) : built
  sourceEntities.set(next, entities)
  return next
}

/** Keys of the blocks whose identity changed between two documents; for tests and diagnostics. */
export const changedBlockKeys = (prev: TextDocument, next: TextDocument): string[] => {
  const before = new Map(prev.blocks.map((block) => [block.key, block]))
  return next.blocks.filter((block) => before.get(block.key) !== block).map((block) => block.key)
}
