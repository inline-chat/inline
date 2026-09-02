import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { isMarkdownEscapable } from "./escape"
import { readMathCandidate } from "./math"
import { linkLabelEnd, readInlineLinkDestination } from "./linkSyntax"
import type { EntityRange } from "./types"

export const maxInlineStyleDepth = 32

/** Exact, attribute-free tags also represent native ranges whose punctuation
 * or whitespace cannot satisfy Markdown delimiter flanking rules. */
export const inlineStyleTags = [
  { type: MessageEntity_Type.BOLD, open: "<b>", close: "</b>" },
  { type: MessageEntity_Type.ITALIC, open: "<i>", close: "</i>" },
  { type: MessageEntity_Type.UNDERLINE, open: "<u>", close: "</u>" },
  { type: MessageEntity_Type.STRIKETHROUGH, open: "<s>", close: "</s>" },
  { type: MessageEntity_Type.HIGHLIGHT, open: "<mark>", close: "</mark>" },
] as const

export const additionalInlineStyles = [
  ...inlineStyleTags,
  { type: MessageEntity_Type.STRIKETHROUGH, open: "~~", close: "~~" },
  { type: MessageEntity_Type.HIGHLIGHT, open: "==", close: "==" },
] as const

type InlineStyle = { open: string; close: string }

const literalHTMLToken = /<\/?[A-Za-z][A-Za-z0-9:-]*(?=[\s/>])(?:[^<>"']|"[^"]*"|'[^']*')*>/y
const literalHTMLDelimiters = [["<!--", "-->"], ["<?", "?>"], ["<![CDATA[", "]]>"]] as const
const structuralTags = new Set(["<details>", "<details open>", "</details>", "<summary>", '<summary kind="progress">', "</summary>", "<footer>", "</footer>"])

/** Keep unsupported HTML tokens literal, including known-looking style tags
 * inside quoted attributes/comments. Only the explicit style/block vocabulary
 * is left for Inline's existing parsers; this never renders or executes HTML. */
export function literalHTMLTokenEnd(text: string, start: number, sourceEnd = text.length): number | undefined {
  if (text[start] !== "<") return undefined
  for (const [open, close] of literalHTMLDelimiters) {
    if (start + open.length > sourceEnd || !text.startsWith(open, start)) continue
    const end = text.indexOf(close, start + open.length)
    // An unfinished comment/declaration owns the remaining source surface.
    // Do not rescan its nested openers or interpret streamed inner syntax.
    return end < 0 || end + close.length > sourceEnd ? sourceEnd : end + close.length
  }
  if (start + 2 < sourceEnd && text[start + 1] === "!" && /[A-Z]/.test(text[start + 2]!)) {
    const end = text.indexOf(">", start + 3)
    return end < 0 || end >= sourceEnd ? sourceEnd : end + 1
  }
  literalHTMLToken.lastIndex = start
  const match = literalHTMLToken.exec(text)
  if (!match || start + match[0].length > sourceEnd || structuralTags.has(match[0])
    || inlineStyleTags.some((style) => style.open === match[0] || style.close === match[0])) return undefined
  return start + match[0].length
}

const paddedEmphasisStyles = [
  { type: MessageEntity_Type.BOLD, open: "**", close: "**" },
  { type: MessageEntity_Type.BOLD, open: "__", close: "__" },
  { type: MessageEntity_Type.ITALIC, open: "*", close: "*" },
  { type: MessageEntity_Type.ITALIC, open: "_", close: "_" },
] as const

/** Preserve Inline's established single-line whitespace-padded formatting.
 * All ordinary emphasis uses verified CommonMark document spans instead. */
export function readPaddedEmphasis(text: string, start: number, sourceEnd = text.length, links: readonly EntityRange[] = []) {
  if (text[start] !== "*" && text[start] !== "_") return undefined
  for (const style of paddedEmphasisStyles) {
    if (!matchesMarker(text, start, style.open)) continue
    if (style.open[0] === "_" && /[\p{L}\p{N}_]$/u.test(text.slice(Math.max(0, start - 2), start))) continue
    const span = readInlineStyle(text, start, style, sourceEnd, { links })
    if (!span || /[\r\n]/.test(text.slice(start, span.end))) continue
    if (!/\s/u.test(text[span.contentStart] ?? "") && !/\s/u.test(text[span.contentEnd - 1] ?? "")) continue
    if (style.open[0] === "_" && /^[\p{L}\p{N}_]/u.test(text.slice(span.end, span.end + 2))) continue
    return { ...span, start, type: style.type }
  }
  return undefined
}

/** Shared span recognition for send/edit and translation; offsets are UTF-16. */
export function readInlineStyle(text: string, start: number, style: InlineStyle, sourceEnd = text.length,
  options: { joinedEmphasis?: boolean; links?: readonly EntityRange[] } = {}): {
  contentStart: number
  contentEnd: number
  end: number
} | undefined {
  if (!(options.joinedEmphasis ? text.startsWith(style.open, start) : matchesMarker(text, start, style.open)) || isEscaped(text, start)) return undefined

  const contentStart = start + style.open.length
  const links = options.links ?? []
  let linkIndex = 0, high = links.length
  while (linkIndex < high) {
    const middle = (linkIndex + high) >>> 1
    if (links[middle]!.start < contentStart) linkIndex = middle + 1
    else high = middle
  }
  let depth = 1
  for (let cursor = contentStart; cursor < sourceEnd; cursor++) {
    if (options.joinedEmphasis && (text[cursor] === "\r" || text[cursor] === "\n")) return undefined
    while (links[linkIndex] && links[linkIndex]!.end <= cursor) linkIndex++
    const resolvedLink = links[linkIndex]
    if (resolvedLink?.start === cursor && resolvedLink.end <= sourceEnd) {
      cursor = resolvedLink.end - 1
      continue
    }
    const htmlEnd = literalHTMLTokenEnd(text, cursor, sourceEnd)
    if (htmlEnd !== undefined) { cursor = htmlEnd - 1; continue }
    const math = text[cursor] === "$" && readMathCandidate(text, cursor)
    if (math) {
      cursor = math.end - 1
      continue
    }
    if (text[cursor] === "\\" && isMarkdownEscapable(text[cursor + 1])) {
      cursor++
      continue
    }
    if (text[cursor] === "[") {
      const labelEnd = linkLabelEnd(text, cursor)
      const link = labelEnd !== undefined && text[labelEnd + 1] === "("
        ? readInlineLinkDestination(text, labelEnd + 2, cursor) : undefined
      if (link && link.end <= sourceEnd) {
        cursor = link.end - 1
        continue
      }
    }
    if (text[cursor] === "\n") {
      let next = cursor + 1
      while (text[next] === " " || text[next] === "\t") next++
      if (text[next] === "\n") return undefined
    }
    if (text[cursor] === "]" && text[cursor + 1] === "(") {
      let end = cursor + 2
      let parentheses = 1
      while (end < sourceEnd && parentheses > 0) {
        if (text[end] === "\\" && isMarkdownEscapable(text[end + 1])) {
          end += 2
          continue
        }
        if (text[end] === "(") parentheses++
        if (text[end] === ")") parentheses--
        end++
      }
      if (parentheses === 0) {
        cursor = end - 1
        continue
      }
    }
    if (text[cursor] === "`") {
      let runEnd = cursor + 1
      while (text[runEnd] === "`") runEnd++
      const marker = text.slice(cursor, runEnd)
      let close = text.indexOf(marker, runEnd)
      while (close >= 0 && close < sourceEnd && (text[close - 1] === "`" || text[close + marker.length] === "`")) {
        close = text.indexOf(marker, close + 1)
      }
      if (close >= 0 && close + marker.length <= sourceEnd) {
        cursor = close + marker.length - 1
        continue
      }
      cursor = runEnd - 1
      continue
    }
    if (style.open !== style.close && matchesMarker(text, cursor, style.open)) {
      if (++depth > maxInlineStyleDepth) return undefined
      cursor += style.open.length - 1
      continue
    }
    if (cursor + style.close.length > sourceEnd || !matchesMarker(text, cursor, style.close)) continue
    if (--depth > 0) {
      cursor += style.close.length - 1
      continue
    }
    if (cursor === contentStart || (style.open === style.close && text.slice(contentStart, cursor).trim().length === 0)) return undefined
    return { contentStart, contentEnd: cursor, end: cursor + style.close.length }
  }
  return undefined
}

function matchesMarker(text: string, index: number, marker: string): boolean {
  if (!text.startsWith(marker, index)) return false
  if (marker === "~~" || marker === "==" || marker === "*" || marker === "**" || marker === "_" || marker === "__") {
    return text[index - 1] !== marker[0] && text[index + marker.length] !== marker[0]
  }
  return true
}

function isEscaped(text: string, index: number): boolean {
  let slashes = 0
  while (index > 0 && text[--index] === "\\") slashes++
  return slashes % 2 === 1
}
