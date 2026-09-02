import { isMarkdownEscapable, unescapeLinkUrl } from "./escape"
import { readMathCandidate } from "./math"
import { fromMarkdown } from "mdast-util-from-markdown"
import { gfmFromMarkdown } from "mdast-util-gfm"
import { gfm } from "micromark-extension-gfm"
import { sourceRangesWithin } from "../../message/markdownSourceMap"

/** Read after `](`. A title is metadata, never part of the URL payload. */
export function readInlineLinkDestination(text: string, start: number, linkStart?: number,
  labelCodeRanges: { start: number; end: number }[] = []): { url: string; end: number } | undefined {
  if (start < 0 || start >= text.length) return undefined
  const finish = (value: string, end: number): { url: string; end: number } | undefined => {
    // Ordinary one-line links need only the scanner. A multiline candidate
    // cannot swallow a heading/fence/HTML/table block that interrupts prose.
    let source = linkStart === undefined ? `[x](${text.slice(start, end)}` : text.slice(linkStart, end)
    if (/[\r\n]/.test(source)) {
      if (linkStart !== undefined) {
        const pieces: string[] = []
        const codes = new Map(sourceRangesWithin(labelCodeRanges, linkStart + 1, start - 2).map((range) => [range.start, range.end]))
        let previous = 0
        for (let cursor = linkStart + 1; cursor < start - 2;) {
          const codeEnd = codes.get(cursor)
          const opaque = codeEnd === undefined ? labelOpaqueSpan(text, cursor) : { end: codeEnd, math: false }
          // Verified code can contain continuation prefixes that only make
          // sense in its parent container. Keep the URL/title boundary guard.
          if ((opaque?.math || codeEnd !== undefined) && opaque && opaque.end <= start - 2) {
            const lower = cursor - linkStart, upper = opaque.end - linkStart
            pieces.push(source.slice(previous, lower), "x".repeat(upper - lower))
            previous = upper
          }
          cursor = opaque?.end ?? cursor + 1
        }
        pieces.push(source.slice(previous))
        source = pieces.join("")
      }
      const root = fromMarkdown(source, { extensions: [gfm()], mdastExtensions: [gfmFromMarkdown()] })
      const paragraph = root.children[0]
      const link = paragraph?.type === "paragraph" ? paragraph.children[0] : undefined
      if (root.children.length !== 1 || paragraph?.type !== "paragraph" || paragraph.children.length !== 1
        || link?.type !== "link" || link.position?.end.offset !== source.length) return undefined
    }
    return { url: unescapeLinkUrl(value), end }
  }
  const contentStart = skipLinkWhitespace(text, start)
  if (contentStart === undefined) return undefined
  const destination = readDestination(text, contentStart)
  if (destination) {
    const after = skipLinkWhitespace(text, destination.end)
    if (after !== undefined) {
      if (text[after] === ")") return finish(destination.value, after + 1)
      if (after > destination.end) {
        const titleEnd = readTitle(text, after)
        const close = titleEnd === undefined ? undefined : skipLinkWhitespace(text, titleEnd)
        if (close !== undefined && text[close] === ")") {
          return finish(destination.value, close + 1)
        }
      }
    }
  }
  // A title containing spaces can appear without a destination. Prefer a
  // valid destination first, so ("one-word") retains its historical URL.
  const titleEnd = readTitle(text, contentStart)
  const close = titleEnd === undefined ? undefined : skipLinkWhitespace(text, titleEnd)
  return close !== undefined && text[close] === ")" ? finish("", close + 1) : undefined
}

function readDestination(text: string, start: number): { value: string; end: number } | undefined {
  if (text[start] === "<") {
    for (let cursor = start + 1; cursor < text.length; cursor++) {
      const char = text[cursor]
      if (char === "\\" && isMarkdownEscapable(text[cursor + 1])) { cursor++; continue }
      if (char === ">") return { value: text.slice(start + 1, cursor), end: cursor + 1 }
      if (char === "<" || char === "\r" || char === "\n") return undefined
    }
    return undefined
  }
  let depth = 0, cursor = start
  for (; cursor < text.length; cursor++) {
    const char = text[cursor]!
    if (char === "\\" && isMarkdownEscapable(text[cursor + 1])) { cursor++; continue }
    if (char.charCodeAt(0) <= 0x20 || char === "\x7f") break
    if (char === "(" && ++depth > 32) return undefined
    if (char === ")") {
      if (depth === 0) break
      depth--
    }
  }
  return depth === 0 ? { value: text.slice(start, cursor), end: cursor } : undefined
}

function readTitle(text: string, start: number): number | undefined {
  const open = text[start]
  if (open !== '"' && open !== "'" && open !== "(") return undefined
  const close = open === "(" ? ")" : open
  let lineBreak = false
  for (let cursor = start + 1; cursor < text.length; cursor++) {
    const char = text[cursor]
    if (char === "\\" && isMarkdownEscapable(text[cursor + 1])) { cursor++; lineBreak = false; continue }
    if (char === close) return cursor + 1
    if (open === "(" && char === "(") return undefined
    if (char === "\r" || char === "\n") {
      if (lineBreak) return undefined
      lineBreak = true
      if (char === "\r" && text[cursor + 1] === "\n") cursor++
    } else if (char !== " " && char !== "\t") lineBreak = false
  }
  return undefined
}

function skipLinkWhitespace(text: string, start: number): number | undefined {
  let cursor = start, lineBreak = false
  while (cursor < text.length) {
    const char = text[cursor]
    if (char === " " || char === "\t") { cursor++; continue }
    if (char !== "\r" && char !== "\n") break
    if (lineBreak) return undefined
    lineBreak = true
    cursor += char === "\r" && text[cursor + 1] === "\n" ? 2 : 1
  }
  return cursor
}

/** Finds the label boundary without interpreting brackets inside code or TeX. */
export function linkLabelEnd(text: string, start: number): number | undefined {
  let depth = 1
  for (let cursor = start + 1; cursor < text.length; cursor++) {
    const opaque = labelOpaqueSpan(text, cursor)
    if (opaque) { cursor = opaque.end - 1; continue }
    if (text[cursor] === "[" && ++depth > 32) return undefined
    if (text[cursor] === "]" && --depth === 0) return cursor
  }
  return undefined
}

function labelOpaqueSpan(text: string, cursor: number): { end: number; math?: boolean } | undefined {
  const math = text[cursor] === "$" && readMathCandidate(text, cursor)
  if (math) return { end: math.end, math: true }
  if (text[cursor] === "\\" && isMarkdownEscapable(text[cursor + 1])) return { end: cursor + 2 }
  if (text[cursor] !== "`") return undefined
  let end = cursor + 1
  while (text[end] === "`") end++
  const marker = text.slice(cursor, end)
  let close = text.indexOf(marker, end)
  while (close >= 0 && (text[close - 1] === "`" || text[close + marker.length] === "`")) {
    close = text.indexOf(marker, close + marker.length)
  }
  return { end: close >= 0 ? close + marker.length : end }
}
