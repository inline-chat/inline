/**
 * Grapheme and word boundaries with `Intl.Segmenter`, limited to the current
 * line and a window around the caret so a keypress never segments the whole
 * draft. The window (4096 code units) is far longer than any real grapheme
 * cluster or word.
 */

const WINDOW = 4096

let graphemes: Intl.Segmenter | undefined
let words: Intl.Segmenter | undefined

const graphemeSegmenter = () => (graphemes ??= new Intl.Segmenter(undefined, { granularity: "grapheme" }))
const wordSegmenter = () => (words ??= new Intl.Segmenter(undefined, { granularity: "word" }))

export const lineStartOf = (text: string, offset: number): number =>
  offset <= 0 ? 0 : text.lastIndexOf("\n", offset - 1) + 1

export const lineEndOf = (text: string, offset: number): number => {
  const index = text.indexOf("\n", offset)
  return index === -1 ? text.length : index
}

/** The grapheme boundary before `offset` (on the same line), or `offset - 1` across a line break. */
export const previousGrapheme = (text: string, offset: number): number => {
  if (offset <= 0) return 0
  const lineStart = lineStartOf(text, offset)
  if (lineStart === offset) return offset - 1
  const start = Math.max(lineStart, offset - WINDOW)
  let boundary = start
  for (const segment of graphemeSegmenter().segment(text.slice(start, offset))) {
    boundary = start + segment.index
  }
  return boundary
}

/** The grapheme boundary after `offset` (on the same line), or `offset + 1` across a line break. */
export const nextGrapheme = (text: string, offset: number): number => {
  if (offset >= text.length) return text.length
  const lineEnd = lineEndOf(text, offset)
  if (lineEnd === offset) return offset + 1
  const end = Math.min(lineEnd, offset + WINDOW)
  const first = graphemeSegmenter().segment(text.slice(offset, end))[Symbol.iterator]().next()
  if (first.done) return offset + 1
  return offset + first.value.segment.length
}

const isSpace = (segment: string) => /^\s+$/u.test(segment)

/**
 * Where a word deletion backward from `offset` stops: skip whitespace, then
 * remove one word (or one run of punctuation). At the start of a line it
 * removes the line break.
 */
export const previousWordBoundary = (text: string, offset: number): number => {
  if (offset <= 0) return 0
  const lineStart = lineStartOf(text, offset)
  if (lineStart === offset) return offset - 1
  const start = Math.max(lineStart, offset - WINDOW)
  const segments = [...wordSegmenter().segment(text.slice(start, offset))]
  let i = segments.length - 1
  while (i >= 0 && isSpace(segments[i]!.segment)) i--
  if (i < 0) return start
  return start + segments[i]!.index
}

/** The forward counterpart of `previousWordBoundary`. */
export const nextWordBoundary = (text: string, offset: number): number => {
  if (offset >= text.length) return text.length
  const lineEnd = lineEndOf(text, offset)
  if (lineEnd === offset) return offset + 1
  const end = Math.min(lineEnd, offset + WINDOW)
  const segments = [...wordSegmenter().segment(text.slice(offset, end))]
  let i = 0
  while (i < segments.length && isSpace(segments[i]!.segment)) i++
  const segment = segments[i]
  if (!segment) return end
  return offset + segment.index + segment.segment.length
}
