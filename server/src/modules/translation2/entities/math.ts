/** Bounds are UTF-16 units, matching canonical message and entity offsets. */
export const mathLimits = { inlineSource: 2_048, displaySource: 8_192 } as const

export type MathSpan = {
  contentStart: number
  contentEnd: number
  end: number
  display: boolean
}

const escapedAt = (text: string, position: number): boolean => {
  let count = 0
  while (position > 0 && text[--position] === "\\") count++
  return count % 2 === 1
}

/** Recognizes only complete, bounded source spans; does not interpret or execute TeX. */
export function readMathSpan(text: string, start: number): MathSpan | undefined {
  const span = readMathCandidate(text, start)
  const limit = span?.display ? mathLimits.displaySource : mathLimits.inlineSource
  return span && span.contentEnd - span.contentStart <= limit ? span : undefined
}

/** Complete unsupported candidates also shield their source from Markdown rewriting. */
export function readMathCandidate(text: string, start: number): MathSpan | undefined {
  if (escapedAt(text, start)) return undefined
  let open: string
  let close: string
  let display: boolean
  if (text.startsWith("$$", start)) {
    if ((text[start - 1] === "$" && !escapedAt(text, start - 1)) || text[start + 2] === "$") return undefined
    open = close = "$$"; display = true
  } else if (text[start] === "$") {
    if ((text[start - 1] === "$" && !escapedAt(text, start - 1)) || text[start + 1] === "$" || /\s/u.test(text[start + 1] ?? "")) return undefined
    open = close = "$"; display = false
  } else {
    return undefined
  }

  const contentStart = start + open.length
  for (let cursor = contentStart; cursor < text.length; cursor++) {
    if (text.startsWith(close, cursor)) {
      if (open === "$" && (text[cursor + 1] === "$" || /\s/u.test(text[cursor - 1] ?? "") || /[0-9]/u.test(text[cursor + 1] ?? ""))) {
        return undefined
      }
      if (open === "$$" && text[cursor + 2] === "$") return undefined
      if (text.slice(contentStart, cursor).trim().length === 0) return undefined
      return { contentStart, contentEnd: cursor, end: cursor + close.length, display }
    }
    if (open === "$" && (text[cursor] === "\n" || text[cursor] === "\r")) return undefined
    // Escaped closing punctuation and TeX control sequences belong to the source body.
    if (text[cursor] === "\\") cursor++
  }
  return undefined
}

/** A double-dollar span is structural only when it owns its source line. */
export function isBlockMathSpan(text: string, start: number, span: MathSpan): boolean {
  if (!span.display) return false
  let lineStart = start
  while (lineStart > 0 && text[lineStart - 1] !== "\n" && text[lineStart - 1] !== "\r") lineStart--
  let lineEnd = span.end
  while (lineEnd < text.length && text[lineEnd] !== "\n" && text[lineEnd] !== "\r") lineEnd++
  return /^ {0,3}$/.test(text.slice(lineStart, start)) && text.slice(span.end, lineEnd).trim().length === 0
}

/** Never escape TeX itself: doing so changes a formula's meaning. */
export function mathMarkdown(source: string, display = false): string | undefined {
  const result = display ? `$$${source}$$` : `$${source}$`
  const span = readMathSpan(result, 0)
  return span?.end === result.length && result.slice(span.contentStart, span.contentEnd) === source
    ? result : undefined
}
