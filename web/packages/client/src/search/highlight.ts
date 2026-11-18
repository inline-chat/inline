import { MAX_INDEXED_TEXT_LENGTH, tokenize, type SearchToken } from "./normalize"
import type { ParsedQuery, QueryGroup } from "./query"

/** A half-open range `[start, end)` in UTF-16 code units of the original text. */
export type TextRange = readonly [start: number, end: number]

/** At most this many ranges per message. */
export const MAX_RANGES = 64

const groupMatchesAt = (
  tokens: readonly SearchToken[],
  at: number,
  group: QueryGroup,
): TextRange | undefined => {
  const count = group.tokens.length
  if (at + count > tokens.length) return undefined
  for (let k = 0; k < count; k++) {
    const token = tokens[at + k]!
    const wanted = group.tokens[k]!
    const isLast = k === count - 1
    if (isLast && group.prefix) {
      if (!token.text.startsWith(wanted)) return undefined
    } else if (token.text !== wanted) {
      return undefined
    }
  }
  const first = tokens[at]!
  const last = tokens[at + count - 1]!
  const lastWanted = group.tokens[count - 1]!
  const end =
    group.prefix && lastWanted.length < last.text.length
      ? (last.unitEnds?.[lastWanted.length - 1] ?? last.end)
      : last.end
  return [first.start, end]
}

const merge = (ranges: TextRange[]): TextRange[] => {
  ranges.sort((a, b) => a[0] - b[0] || a[1] - b[1])
  const out: [number, number][] = []
  for (const [start, end] of ranges) {
    const previous = out[out.length - 1]
    if (previous && start <= previous[1]) previous[1] = Math.max(previous[1], end)
    else out.push([start, end])
  }
  return out
}

/**
 * Where the query matches `text`, as FTS5 matched it: every occurrence of
 * every phrase, in UTF-16 offsets of `text`, sorted and merged. `undefined`
 * when some phrase does not occur, which means the message no longer
 * matches (FTS5 requires all of them).
 */
export const matchRanges = (
  text: unknown,
  query: ParsedQuery,
): TextRange[] | undefined => {
  const tokens = tokenize(text, { withUnits: true, maxLength: MAX_INDEXED_TEXT_LENGTH })
  const ranges: TextRange[] = []
  for (const group of query.groups) {
    let found = false
    for (let at = 0; at < tokens.length; at++) {
      const range = groupMatchesAt(tokens, at, group)
      if (!range) continue
      found = true
      if (ranges.length < MAX_RANGES * 4) ranges.push(range)
    }
    if (!found) return undefined
  }
  return merge(ranges).slice(0, MAX_RANGES)
}

const isWhitespace = (code: number) =>
  code === 32 || (code >= 9 && code <= 13) || code === 0xa0 || code === 0x2028 || code === 0x2029

const isLowSurrogate = (code: number) => code >= 0xdc00 && code <= 0xdfff

/**
 * An excerpt of `text` around its first range, with "..." where it was cut
 * and runs of whitespace shown as one space, and the ranges that fall inside
 * it moved into the excerpt's offsets. The Mac's `LocalMessageSearch.snippet`
 * (radius 70), driven by the computed ranges instead of a second search.
 */
export const messageSnippet = (
  text: string,
  ranges: readonly TextRange[],
  radius = 70,
): { snippet: string; ranges: TextRange[] } => {
  const source = typeof text === "string" ? text : ""
  let start = 0
  let end = source.length
  const anchor = ranges[0]
  if (anchor) {
    start = Math.max(0, anchor[0] - radius)
    end = Math.min(source.length, anchor[1] + radius)
  } else {
    end = Math.min(source.length, radius * 2)
  }
  // Never split a surrogate pair.
  if (start > 0 && isLowSurrogate(source.charCodeAt(start))) start -= 1
  if (end < source.length && isLowSurrogate(source.charCodeAt(end))) end += 1

  // Build the excerpt, collapsing whitespace, with a map from source offsets.
  const map = new Int32Array(end - start + 1)
  let out = ""
  let pendingSpace = false
  for (let i = start; i < end; i++) {
    const code = source.charCodeAt(i)
    if (isWhitespace(code)) {
      map[i - start] = out.length
      pendingSpace = out.length > 0
      continue
    }
    if (pendingSpace) out += " "
    pendingSpace = false
    map[i - start] = out.length
    out += source[i]
  }
  map[end - start] = out.length
  const prefix = start > 0 ? "..." : ""
  const suffix = end < source.length ? "..." : ""
  const shifted: TextRange[] = []
  for (const [from, to] of ranges) {
    if (to <= start || from >= end) continue
    const a = map[Math.max(from, start) - start]! + prefix.length
    const b = map[Math.min(to, end) - start]! + prefix.length
    if (b > a) shifted.push([a, b])
  }
  return { snippet: prefix + out + suffix, ranges: shifted }
}
