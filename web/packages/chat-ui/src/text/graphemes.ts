/**
 * Grapheme helpers over UTF-16 strings. Offsets are UTF-16 code units, as in
 * message entities. Uses `Intl.Segmenter`, which every supported browser and
 * Node have; without it they fall back to code points.
 */

const segmenter: Intl.Segmenter | undefined =
  typeof Intl !== "undefined" && typeof Intl.Segmenter === "function"
    ? new Intl.Segmenter(undefined, { granularity: "grapheme" })
    : undefined

export const isHighSurrogate = (unit: number): boolean => unit >= 0xd800 && unit <= 0xdbff
export const isLowSurrogate = (unit: number): boolean => unit >= 0xdc00 && unit <= 0xdfff

/** True when `offset` falls between the two halves of a surrogate pair. */
export const splitsSurrogatePair = (text: string, offset: number): boolean =>
  offset > 0 &&
  offset < text.length &&
  isHighSurrogate(text.charCodeAt(offset - 1)) &&
  isLowSurrogate(text.charCodeAt(offset))

/**
 * How far around an offset to look for the cluster that contains it. Clusters
 * longer than this (long Zalgo stacks) are treated as ending at the window.
 */
const window = 64

/**
 * The grapheme cluster boundaries nearest to `offset`: `[start, end]` of the
 * cluster that contains the code unit just before `offset`, or `[offset,
 * offset]` when `offset` is already a boundary.
 */
const clusterAround = (text: string, offset: number): readonly [number, number] => {
  if (offset <= 0 || offset >= text.length) return [offset, offset]
  const before = text.charCodeAt(offset - 1)
  const after = text.charCodeAt(offset)
  // Two ASCII units are always a boundary, except CR LF.
  if (before < 0x80 && after < 0x80) return before === 0x0d && after === 0x0a ? [offset - 1, offset + 1] : [offset, offset]
  if (!segmenter) {
    return isHighSurrogate(before) && isLowSurrogate(after) ? [offset - 1, offset + 1] : [offset, offset]
  }
  const from = Math.max(0, offset - window)
  const to = Math.min(text.length, offset + window)
  for (const segment of segmenter.segment(text.slice(from, to))) {
    const start = from + segment.index
    const end = start + segment.segment.length
    if (start === offset || end === offset) return [offset, offset]
    if (start < offset && end > offset) return [start, end]
  }
  return [offset, offset]
}

/** `offset` moved back to the start of the grapheme cluster it falls inside. */
export const graphemeStartAtOrBefore = (text: string, offset: number): number => clusterAround(text, offset)[0]

/** `offset` moved forward to the end of the grapheme cluster it falls inside. */
export const graphemeEndAtOrAfter = (text: string, offset: number): number => clusterAround(text, offset)[1]

/** The first grapheme cluster of `text`, or `""`. */
export const firstGrapheme = (text: string): string => {
  if (text.length === 0) return ""
  if (segmenter) {
    for (const segment of segmenter.segment(text.slice(0, window))) return segment.segment
  }
  const codePoint = text.codePointAt(0) ?? 0
  return String.fromCodePoint(codePoint)
}

export const ellipsis = "\u2026"

/**
 * `text` cut to at most `max` grapheme clusters, ending in `suffix` when it
 * was cut. Never splits an emoji, a combining sequence or a surrogate pair.
 * The suffix counts toward `max`.
 */
export const truncateGraphemes = (text: string, max: number, suffix: string = ellipsis): string => {
  const limit = Math.max(0, Math.floor(max))
  // Code units are never fewer than graphemes.
  if (text.length <= limit) return text
  if (limit === 0) return ""
  const keep = suffix.length > 0 ? limit - 1 : limit
  let count = 0
  let cut = 0
  let index = 0
  const pieces: Iterable<string> = segmenter
    ? (function* () {
        for (const segment of segmenter.segment(text)) yield segment.segment
      })()
    : text
  for (const piece of pieces) {
    if (count === keep) cut = index
    count += 1
    if (count > limit) return `${text.slice(0, cut).trimEnd()}${suffix}`
    index += piece.length
  }
  return text
}
