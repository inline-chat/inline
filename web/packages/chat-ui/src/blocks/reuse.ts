/**
 * Structural sharing for block trees, for streaming: an agent edits its
 * message many times a second, usually by appending to the last block.
 * `updateBlockTree` returns the previous object for every node that did not
 * change, so a view comparing by identity touches one block.
 *
 * Same rules as the text model's `reuseUnchanged` (keyed arrays match by
 * key), plus byte arrays compare by content, since rows arrive as fresh
 * copies across a worker boundary.
 */

import type { MessageRow } from "@inline/core-protocol"
import { buildBlockTree, type BlockTreeOptions } from "./build"
import type { BlockTree } from "./types"

const isKeyed = (value: unknown): value is { readonly key: string } =>
  typeof value === "object" && value !== null && typeof (value as { key?: unknown }).key === "string"

const isPlainObject = (value: unknown): value is Record<string, unknown> => {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false
  const proto: unknown = Object.getPrototypeOf(value)
  return proto === Object.prototype || proto === null
}

const sameBytes = (a: Uint8Array, b: Uint8Array): boolean => {
  if (a.length !== b.length) return false
  for (let index = 0; index < a.length; index += 1) if (a[index] !== b[index]) return false
  return true
}

export const reuseTree = <T>(prev: T, next: T): T => {
  if (Object.is(prev, next)) return prev
  if (prev instanceof Uint8Array && next instanceof Uint8Array) return sameBytes(prev, next) ? prev : next
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
    const reused = match === undefined ? item : reuseTree(match, item)
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
    const reused = key in prev ? reuseTree(prev[key], next[key]) : next[key]
    if (reused !== prev[key]) same = false
    out[key] = reused
  }
  return same ? prev : out
}

type Input = Pick<MessageRow, "text" | "entities" | "blocks" | "actions" | "date">

const sources = new WeakMap<BlockTree, { readonly row: Input; readonly options: BlockTreeOptions | undefined }>()

const shallowEqual = (a: unknown, b: unknown): boolean => {
  if (Object.is(a, b)) return true
  if (Array.isArray(a) && Array.isArray(b)) return a.length === b.length && a.every((item, index) => Object.is(item, b[index]))
  if (!isPlainObject(a) || !isPlainObject(b)) return false
  const keys = Object.keys(a)
  if (keys.length !== Object.keys(b).length) return false
  return keys.every((key) => key in b && (Object.is(a[key], b[key]) || shallowEqual(a[key], b[key])))
}

const sameMap = (a: ReadonlyMap<string, boolean> | undefined, b: ReadonlyMap<string, boolean> | undefined): boolean => {
  if (a === b) return true
  if ((a?.size ?? 0) !== (b?.size ?? 0)) return false
  for (const [key, value] of a ?? []) if (b?.get(key) !== value) return false
  return true
}

const rangeEnds = (range: unknown): [unknown, unknown] =>
  Array.isArray(range) ? [range[0], range[1]] : [(range as { start?: unknown })?.start, (range as { end?: unknown })?.end]

const sameRanges = (a: BlockTreeOptions["highlightRanges"], b: BlockTreeOptions["highlightRanges"]): boolean => {
  if (a === b) return true
  if ((a?.length ?? 0) !== (b?.length ?? 0)) return false
  return (a ?? []).every((range, index) => {
    const [aStart, aEnd] = rangeEnds(range)
    const [bStart, bEnd] = rangeEnds(b?.[index])
    return aStart === bStart && aEnd === bEnd
  })
}

/**
 * Whether two option sets build the same tree. Structural and cheap: scalar
 * fields by value, `text` and `links` one or two levels deep, the disclosure
 * map by entries. A caller that passes a fresh but equal options object each
 * render still gets `prev` back.
 */
export const sameBlockTreeOptions = (a: BlockTreeOptions | undefined, b: BlockTreeOptions | undefined): boolean => {
  if (a === b) return true
  const left = a ?? {}
  const right = b ?? {}
  return (
    left.availableWidth === right.availableWidth &&
    left.now === right.now &&
    shallowEqual(left.text, right.text) &&
    shallowEqual(left.links, right.links) &&
    sameMap(left.openDisclosures, right.openDisclosures) &&
    sameRanges(left.highlightRanges, right.highlightRanges)
  )
}

/**
 * The tree for `row`, reusing every unchanged node of `prev`. Returns `prev`
 * itself when the row's content fields are the same objects as last time and
 * the options are structurally the same. When only the options change (a
 * disclosure toggled), the tree is rebuilt and every block whose output did
 * not change keeps its identity. Undefined means "render the flat text" (see
 * `buildBlockTree`).
 */
export const updateBlockTree = (
  prev: BlockTree | undefined,
  row: Input,
  options?: BlockTreeOptions,
): BlockTree | undefined => {
  const source = prev ? sources.get(prev) : undefined
  if (
    prev &&
    source &&
    source.row.text === row.text &&
    source.row.entities === row.entities &&
    source.row.blocks === row.blocks &&
    source.row.actions === row.actions &&
    source.row.date === row.date &&
    sameBlockTreeOptions(source.options, options)
  ) {
    return prev
  }
  const built = buildBlockTree(row, options)
  if (!built) return undefined
  const next = prev ? reuseTree(prev, built) : built
  sources.set(next, { row, options })
  return next
}

/** Keys of top-level blocks whose identity changed; for tests and diagnostics. */
export const changedRichBlockKeys = (prev: BlockTree | undefined, next: BlockTree | undefined): string[] => {
  const before = new Map((prev?.blocks ?? []).map((block) => [block.key, block]))
  return (next?.blocks ?? []).filter((block) => before.get(block.key) !== block).map((block) => block.key)
}
