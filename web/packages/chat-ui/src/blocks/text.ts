/**
 * Text ranges of a message, for blocks. Ranges are UTF-16 offsets into the
 * message text, as entities are.
 */

import type { TextRange } from "@inline/core-protocol"
import { buildTextDocument, type TextRenderOptions } from "../text/build"
import { applyHighlights } from "../text/highlight"
import type { FindSpan } from "../text/types"
import { splitsSurrogatePair } from "../text/graphemes"
import type { RichText } from "./types"

export type Span = { readonly start: number; readonly end: number }

/** The span of a range, or undefined when it runs past the text or splits a surrogate pair. */
export const rangeSpan = (text: string, range: TextRange | undefined): Span | undefined => {
  if (!range) return undefined
  const { offset, length } = range
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0) return undefined
  if (offset > text.length || length > text.length - offset) return undefined
  const end = offset + length
  if (splitsSurrogatePair(text, offset) || splitsSurrogatePair(text, end)) return undefined
  return { start: offset, end }
}

/** Entities clipped to a span and shifted to its start. Malformed entities pass through for the text model to drop. */
export const clipEntities = (entities: readonly unknown[] | undefined, span: Span): unknown[] => {
  const result: unknown[] = []
  for (const raw of entities ?? []) {
    if (raw === null || typeof raw !== "object") continue
    const entity = raw as { offset?: unknown; length?: unknown }
    if (typeof entity.offset !== "number" || typeof entity.length !== "number") continue
    const start = Math.max(entity.offset, span.start)
    const end = Math.min(entity.offset + entity.length, span.end)
    if (end <= start) continue
    result.push({ ...(raw as object), offset: start - span.start, length: end - start })
  }
  return result
}

/** Find spans (absolute, normalized on the message text) clipped to `span` and made relative to it. */
export const clipFind = (find: readonly FindSpan[] | undefined, span: Span): FindSpan[] => {
  const result: FindSpan[] = []
  for (const range of find ?? []) {
    const start = Math.max(range.start, span.start)
    const end = Math.min(range.end, span.end)
    if (end > start) result.push({ start: start - span.start, end: end - span.start })
  }
  return result
}

export const richText = (
  text: string,
  entities: readonly unknown[] | undefined,
  span: Span,
  options: TextRenderOptions | undefined,
  find?: readonly FindSpan[],
): RichText => {
  const document = buildTextDocument(text.slice(span.start, span.end), clipEntities(entities, span), options)
  const local = clipFind(find, span)
  return { start: span.start, document: local.length > 0 ? applyHighlights(document, local) : document }
}

/** A span with leading and trailing whitespace removed; undefined when nothing is left. */
export const trimSpan = (text: string, span: Span): Span | undefined => {
  let start = span.start
  let end = span.end
  while (start < end && /\s/.test(text[start] ?? "")) start += 1
  while (end > start && /\s/.test(text[end - 1] ?? "")) end -= 1
  return end > start ? { start, end } : undefined
}

export const unionSpan = (a: Span | undefined, b: Span | undefined): Span | undefined => {
  if (!a) return b
  if (!b) return a
  return { start: Math.min(a.start, b.start), end: Math.max(a.end, b.end) }
}
