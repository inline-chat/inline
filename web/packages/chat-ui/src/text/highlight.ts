/**
 * Find-in-chat highlights over a built text document.
 *
 * Ranges are UTF-16 `[start, end)` into the document's text. They are
 * normalized like entities: a range that is not two safe integers with
 * `0 <= start < end <= text.length`, or whose edge splits a surrogate pair,
 * is dropped; edges inside a grapheme cluster widen to the cluster; overlapping
 * and touching ranges merge. At most 1000 ranges are used.
 *
 * Highlighting is a pass over the document's leaves: text runs (top level and
 * inside links, mentions, thread references and bot commands) are split at
 * range edges and the pieces inside a range get the `find` mark. Code blocks
 * are highlighted too (`CodeBlockNode.find`), since a match in code is still a
 * match. Inline and display math stay inert and are not highlighted.
 *
 * Blocks and inline nodes that no range touches are returned as the same
 * objects, so a view that compares by identity re-renders only the touched
 * paragraphs. `highlightTextDocument` also keeps identity across calls with
 * the same document and ranges.
 */

import { marksWith } from "./build"
import { graphemeEndAtOrAfter, graphemeStartAtOrBefore, splitsSurrogatePair } from "./graphemes"
import { reuseUnchanged } from "./reuse"
import type { BlockNode, FindSpan, HighlightRange, InlineNode, ParagraphNode, TextDocument, TextRun } from "./types"

export const MAX_HIGHLIGHT_RANGES = 1000

const endpoints = (range: unknown): [unknown, unknown] => {
  if (Array.isArray(range)) return [range[0], range[1]]
  if (range !== null && typeof range === "object") {
    const record = range as { start?: unknown; end?: unknown }
    return [record.start, record.end]
  }
  return [undefined, undefined]
}

/** Valid, widened, sorted and merged ranges for `text`. Never throws. */
export const normalizeHighlightRanges = (text: string, ranges: unknown): FindSpan[] => {
  if (!Array.isArray(ranges) || ranges.length === 0) return []
  const spans: { start: number; end: number }[] = []
  for (const range of ranges.slice(0, MAX_HIGHLIGHT_RANGES)) {
    const [start, end] = endpoints(range)
    if (typeof start !== "number" || typeof end !== "number") continue
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end)) continue
    if (start < 0 || end <= start || end > text.length) continue
    if (splitsSurrogatePair(text, start) || splitsSurrogatePair(text, end)) continue
    spans.push({ start: graphemeStartAtOrBefore(text, start), end: graphemeEndAtOrAfter(text, end) })
  }
  spans.sort((a, b) => a.start - b.start || a.end - b.end)
  const merged: { start: number; end: number }[] = []
  for (const span of spans) {
    const last = merged[merged.length - 1]
    if (last && span.start <= last.end) last.end = Math.max(last.end, span.end)
    else merged.push({ ...span })
  }
  return merged
}

const touches = (spans: readonly FindSpan[], start: number, end: number): boolean =>
  spans.some((span) => span.start < end && start < span.end)

const splitRun = (run: TextRun, spans: readonly FindSpan[], out: TextRun[]): void => {
  if (!touches(spans, run.start, run.end)) {
    out.push(run)
    return
  }
  const cuts = new Set<number>([run.start, run.end])
  for (const span of spans) {
    if (span.start > run.start && span.start < run.end) cuts.add(span.start)
    if (span.end > run.start && span.end < run.end) cuts.add(span.end)
  }
  const points = [...cuts].sort((a, b) => a - b)
  for (let index = 0; index + 1 < points.length; index += 1) {
    const from = points[index] ?? run.start
    const to = points[index + 1] ?? run.end
    const inside = spans.some((span) => span.start <= from && to <= span.end)
    out.push({
      kind: "text",
      key: `t${from}`,
      start: from,
      end: to,
      text: run.text.slice(from - run.start, to - run.start),
      marks: inside ? marksWith(run.marks, "find") : run.marks,
    })
  }
}

const splitRuns = (runs: readonly TextRun[], spans: readonly FindSpan[]): readonly TextRun[] => {
  const out: TextRun[] = []
  for (const run of runs) splitRun(run, spans, out)
  return out
}

const highlightInline = (node: InlineNode, spans: readonly FindSpan[], out: InlineNode[]): void => {
  if (!touches(spans, node.start, node.end)) {
    out.push(node)
    return
  }
  switch (node.kind) {
    case "text":
      splitRun(node, spans, out as TextRun[])
      return
    case "link":
    case "mention":
    case "threadRef":
    case "botCommand":
      out.push({ ...node, children: splitRuns(node.children, spans) })
      return
    case "math":
      out.push(node)
      return
  }
}

const highlightParagraph = (node: ParagraphNode, spans: readonly FindSpan[]): ParagraphNode => {
  if (!touches(spans, node.start, node.end)) return node
  const children: InlineNode[] = []
  for (const child of node.children) highlightInline(child, spans, children)
  return { ...node, children }
}

const highlightBlock = (node: BlockNode, spans: readonly FindSpan[]): BlockNode => {
  if (!touches(spans, node.start, node.end)) return node
  switch (node.kind) {
    case "paragraph":
      return highlightParagraph(node, spans)
    case "quote":
      return { ...node, children: node.children.map((child) => highlightParagraph(child, spans)) }
    case "codeBlock": {
      const find = spans
        .filter((span) => span.start < node.end && node.start < span.end)
        .map((span) => ({ start: Math.max(span.start, node.start) - node.start, end: Math.min(span.end, node.end) - node.start }))
      return find.length > 0 ? { ...node, find } : node
    }
    default:
      // Display math stays inert; an unknown kind is left as is.
      return node
  }
}

/**
 * `document` with find highlights. Pure: returns `document` itself when no
 * valid range remains, and the same object for every node no range touches.
 */
export const applyHighlights = (document: TextDocument, ranges: readonly HighlightRange[] | undefined): TextDocument => {
  const spans = normalizeHighlightRanges(document.text, ranges)
  if (spans.length === 0) return document
  let changed = false
  const blocks = document.blocks.map((block) => {
    const next = highlightBlock(block, spans)
    if (next !== block) changed = true
    return next
  })
  return changed ? { ...document, blocks } : document
}

const lastResult = new WeakMap<TextDocument, { readonly key: string; readonly result: TextDocument }>()

/**
 * `applyHighlights` with identity across calls: the same document and
 * ranges give the same object, and when only the ranges change, every node
 * whose output is unchanged keeps the object it had last time. This is what
 * `MessageText`'s `highlightRanges` uses.
 */
export const highlightTextDocument = (document: TextDocument, ranges: readonly HighlightRange[] | undefined): TextDocument => {
  const spans = normalizeHighlightRanges(document.text, ranges)
  if (spans.length === 0) return document
  const key = spans.map((span) => `${span.start}-${span.end}`).join(",")
  const previous = lastResult.get(document)
  if (previous?.key === key) return previous.result
  const next = applyHighlights(document, spans)
  let result = next
  if (previous && next !== document) {
    // Untouched blocks are the document's own objects; touched ones reuse last call's objects where equal.
    const before = new Map(previous.result.blocks.map((block) => [block.key, block]))
    let changed = false
    const blocks = next.blocks.map((block, index) => {
      if (block === document.blocks[index]) return block
      const prior = before.get(block.key)
      const reused = prior ? reuseUnchanged(prior, block) : block
      if (reused !== block) changed = true
      return reused
    })
    result = changed ? { ...next, blocks } : next
  }
  lastResult.set(document, { key, result })
  return result
}
