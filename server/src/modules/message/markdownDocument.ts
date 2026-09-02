import type { Code, Definition, ImageReference, InlineCode, Link, LinkReference, Nodes, Root } from "mdast"
import type { Extension, Handle } from "mdast-util-from-markdown"
import { decodeString } from "micromark-util-decode-string"
import type { EntityRange } from "../translation2/entities/types"
import { cleanFenceLanguage } from "../translation2/entities/fences"
import { linkLabelEnd } from "../translation2/entities/linkSyntax"
import { isMarkdownEscapable } from "../translation2/entities/escape"
import { readMathCandidate } from "../translation2/entities/math"
import { inlineStyleTags, readInlineStyle } from "../translation2/entities/inlineStyles"
import { urlEntities } from "../translation2/entities/url"
import { richMarkdownAst } from "./markdownAst"
import { sourceRangesWithin } from "./markdownSourceMap"

export type MarkdownCodeBlock = EntityRange & {
  content: string
  sourceToContent: number[]
  language: string
}
export type MarkdownInlineCode = Omit<MarkdownCodeBlock, "language">
export type MarkdownCharacterReference = EntityRange & { content: string }
export type MarkdownEmphasis = EntityRange & {
  kind: "strong" | "emphasis"
  contentStart: number
  contentEnd: number
  multiline: boolean
}

/** Resolved reference or multiline inline link. Both use the same source-label
 * projection; single-line inline links retain the compatibility scanner. */
export type MarkdownReference = EntityRange & {
  labelStart: number
  labelEnd: number
  url: string
  image: boolean
  blockImage: boolean
}

export type MarkdownDocument = {
  codeBlocks: MarkdownCodeBlock[]
  inlineCodes: MarkdownInlineCode[]
  emphasis: MarkdownEmphasis[]
  characterReferences: MarkdownCharacterReference[]
  references: MarkdownReference[]
  definitions: EntityRange[]
  prefixes: EntityRange[]
  paragraphRanges: EntityRange[]
  /** Disjoint original-source inline surfaces. Undefined on the plain-text fast path. */
  inlineRanges?: EntityRange[]
  root?: Root
}

/** Container punctuation alone is not a visible message after definitions are
 * removed. Math is checked separately by callers because flow TeX is masked. */
export function hasVisibleMarkdownContent(document: MarkdownDocument): boolean {
  if (!document.root) return true
  const pending: Nodes[] = [document.root]
  while (pending.length) {
    const node = pending.pop()!
    if (node.type === "definition") continue
    if ("children" in node) {
      for (const child of node.children) pending.push(child)
    } else if (node.type === "code") {
      if (node.value.length > 0) return true
    } else if (!("value" in node) || typeof node.value !== "string" || node.value.trim().length > 0) return true
  }
  return false
}

type CodeValue = EntityRange & { value: string; padding?: boolean }
type Prefix = EntityRange & { kind: "blockQuotePrefix" | "listItemIndent" | "linePrefix"; containerStart: number; inline: boolean }
type CodeDocument = { root: Root; values: Map<Code | InlineCode, CodeValue[]>; prefixes: Prefix[]; characterReferences: MarkdownCharacterReference[] }

/** Prepare inline syntax once before the compatibility scan. Its AST
 * can also serve the block/reference adapter when no extension masking is needed. */
export function prepareMarkdownInlineSyntax(source: string): { inlineCodes: MarkdownInlineCode[]; emphasis: MarkdownEmphasis[]; syntax?: CodeDocument } | undefined {
  if (!mayContainEmphasis(source) && !(source.includes("`") && /[\r\n]/.test(source))) return { inlineCodes: [], emphasis: [] }
  try {
    const syntax = parseCodeDocument(source)
    return { syntax, inlineCodes: collectInlineCodes(source, syntax), emphasis: collectEmphasis(source, syntax.root) }
  } catch {
    return undefined
  }
}

function collectEmphasis(source: string, root: Root): MarkdownEmphasis[] {
  const result: MarkdownEmphasis[] = []
  const links: EntityRange[] = []
  const continuations: { span: MarkdownEmphasis; scopeEnd: number; size: number }[] = []
  const pending: { node: Nodes; scopeEnd: number }[] = [{ node: root, scopeEnd: source.length }]
  while (pending.length) {
    const item = pending.pop()!
    const { node } = item
    const scopeEnd = node.type === "paragraph" || node.type === "heading" || node.type === "tableCell"
      ? node.position?.end.offset ?? item.scopeEnd : item.scopeEnd
    if (node.type === "link" || node.type === "linkReference" || node.type === "image" || node.type === "imageReference") {
      const start = node.position?.start.offset, end = node.position?.end.offset
      if (start !== undefined && end !== undefined) links.push({ start, end })
    }
    if (node.type === "strong" || node.type === "emphasis") {
      const start = node.position?.start.offset, end = node.position?.end.offset
      if (start === undefined || end === undefined) throw new Error("Missing emphasis position")
      const size = node.type === "strong" ? 2 : 1
      const marker = source.slice(start, start + size)
      if (!/^(?:\*{1,2}|_{1,2})$/.test(marker) || marker !== source.slice(end - size, end) || end - start <= size * 2) {
        throw new Error("Unverified emphasis source range")
      }
      const multiline = /[\r\n]/.test(source.slice(start, end))
      const span: MarkdownEmphasis = { start, end, kind: node.type, contentStart: start + size, contentEnd: end - size, multiline }
      const adjacent = marker[0] === "*" ? adjacentEmphasis(source, span, node.children, size) : undefined
      result.push(...(adjacent ?? [span]))
      if (marker[0] === "*" && source[span.end] === "*") continuations.push({ span, scopeEnd, size })
    }
    if ("children" in node) for (let index = node.children.length - 1; index >= 0; index--) {
      pending.push({ node: node.children[index]!, scopeEnd })
    }
  }
  if (continuations.length) {
    links.sort((a, b) => a.start - b.start || b.end - a.end)
    for (const { span, scopeEnd, size } of continuations) {
      const continuation = adjacentContinuation(source, span, scopeEnd, size, links)
      if (continuation) result.push(continuation)
    }
  }
  return result.sort((a, b) => a.start - b.start || b.end - a.end)
}

function adjacentContinuation(source: string, before: MarkdownEmphasis, scopeEnd: number, size: number, links: EntityRange[]): MarkdownEmphasis | undefined {
  const start = before.end, marker = "*".repeat(size)
  if (source.slice(start - size, start + size) !== marker + marker
    || source[start - size - 1] === "*" || source[start + size] === "*") return undefined
  // Punctuation can stop CommonMark from reopening at the second half of an
  // adjacent run (*one**@Maya*). Keep this existing Inline convention bounded
  // to the same surface, with the shared code/math/link opacity rules.
  const span = readInlineStyle(source, start, { open: marker, close: marker }, scopeEnd, { joinedEmphasis: true, links })
  return span && !/[\r\n]/.test(source.slice(start, span.end))
    ? { ...span, start, kind: before.kind, multiline: false } : undefined
}

/** Inline's serializer has long emitted adjacent ranges as *one**two* or
 * **one****two**. Preserve that dialect only for exact runs in direct text
 * children; nested emphasis, code, TeX, escaped stars and URL targets retain
 * their original grammar. */
function adjacentEmphasis(source: string, span: MarkdownEmphasis, children: Nodes[], size: number): MarkdownEmphasis[] | undefined {
  const boundaries: number[] = []
  for (const child of children) {
    if (child.type !== "text") continue
    const start = child.position?.start.offset, end = child.position?.end.offset
    if (start === undefined || end === undefined) continue
    for (let cursor = start; cursor < end; cursor++) {
      if (source[cursor] === "\\" && isMarkdownEscapable(source[cursor + 1])) { cursor++; continue }
      const math = source[cursor] === "$" && readMathCandidate(source, cursor)
      if (math) { cursor = math.end - 1; continue }
      if (source[cursor] !== "*") continue
      let runEnd = cursor + 1
      while (source[runEnd] === "*") runEnd++
      if (runEnd <= end && source[cursor - 1] !== "*" && runEnd - cursor === size * 2) boundaries.push(cursor)
      cursor = runEnd - 1
    }
  }
  if (!boundaries.length) return undefined
  const result: MarkdownEmphasis[] = []
  let start = span.start
  for (const boundary of boundaries) {
    if (boundary <= start + size || !source.slice(start + size, boundary).trim()) return undefined
    result.push({ ...span, start, end: boundary + size, contentStart: start + size, contentEnd: boundary,
      multiline: /[\r\n]/.test(source.slice(start, boundary + size)) })
    start = boundary + size
  }
  if (start + size >= span.contentEnd || !source.slice(start + size, span.contentEnd).trim()) return undefined
  result.push({ ...span, start, contentStart: start + size, multiline: /[\r\n]/.test(source.slice(start, span.end)) })
  return result
}

function mayContainEmphasis(source: string): boolean {
  return source.indexOf("*") !== source.lastIndexOf("*") || source.indexOf("_") !== source.lastIndexOf("_")
}

export function relativeEmphasis(spans: MarkdownEmphasis[], start: number, end: number): MarkdownEmphasis[] {
  return sourceRangesWithin(spans, start, end).map((span) => ({ ...span,
    start: span.start - start, end: span.end - start, contentStart: span.contentStart - start, contentEnd: span.contentEnd - start }))
}

export function relativeCharacterReferences(spans: MarkdownCharacterReference[], start: number, end: number): MarkdownCharacterReference[] {
  return sourceRangesWithin(spans, start, end).map((span) => ({ ...span, start: span.start - start, end: span.end - start }))
}

/** Keep the parent's grammar when projecting a label or formatting body. */
export function relativeInlineRanges(ranges: EntityRange[] | undefined, start: number, end: number): EntityRange[] | undefined {
  if (!ranges) return undefined
  let low = 0, high = ranges.length
  while (low < high) {
    const middle = (low + high) >>> 1
    if (ranges[middle]!.end <= start) low = middle + 1
    else high = middle
  }
  const result: EntityRange[] = []
  for (let index = low; index < ranges.length; index++) {
    const range = ranges[index]!
    if (range.start >= end) break
    result.push({ start: Math.max(range.start, start) - start, end: Math.min(range.end, end) - start })
  }
  return result
}

export function inlineRangeEnd(ranges: EntityRange[] | undefined, start: number, sourceEnd: number): number {
  if (!ranges) return sourceEnd
  let low = 0, high = ranges.length
  while (low < high) {
    const middle = (low + high) >>> 1
    if (ranges[middle]!.end <= start) low = middle + 1
    else high = middle
  }
  const range = ranges[low]
  return range && range.start <= start ? range.end : start
}

function collectInlineCodes(source: string, document: CodeDocument): MarkdownInlineCode[] {
  const result: MarkdownInlineCode[] = []
  for (const [node, values] of document.values) {
    if (node.type !== "inlineCode" || node.position?.start.line === node.position?.end.line) continue
    const start = node.position?.start.offset, end = node.position?.end.offset
    if (start === undefined || end === undefined) throw new Error("Missing inline code position")
    const mapped = mapInlineCode(source, node, values, start, end)
    if (!mapped) throw new Error("Unverified inline code source map")
    result.push(mapped)
  }
  return result.sort((a, b) => a.start - b.start)
}

export function relativeInlineCodes(codes: MarkdownInlineCode[], start: number, end: number): MarkdownInlineCode[] {
  return sourceRangesWithin(codes, start, end).map((code) => ({ ...code, start: code.start - start, end: code.end - start }))
}

export function mayContainNonRootCode(source: string): boolean {
  // Necessary markers only, not an indentation grammar. The AST decides whether
  // they are code. Ordinary list items must not pay for a second document parse.
  return / {4}|\t|`{3}|~{3}/.test(source) && /^(?:[ \t]|>|(?:[-+*]|\d+[.)])[ \t])/m.test(source)
}

/** Plain streaming prose and single-line list items keep their fast path. The
 * AST decides which candidate containers actually have continuation prefixes. */
export function mayContainMarkdownDocument(source: string): boolean {
  return mayContainEmphasis(source) || source.includes("]:") || mayContainNonRootCode(source)
    || (source.includes("&") && source.includes(";"))
    || (/[`*_~=<]/.test(source) && /[\r\n]/.test(source))
    || (source.includes("|") && /[\r\n]/.test(source))
    || (/^[ \t]*>/m.test(source) && /[\r\n]/.test(source))
    || (/^[ \t]*(?:[-+*]|\d+[.)])[ \t]/m.test(source) && /^[ \t]+\S/m.test(source))
    || /^<details(?: open)?>$/m.test(source)
}

export function markdownDocument(source: string, mathRanges: EntityRange[], extensions: EntityRange[] = [], prepared?: CodeDocument): MarkdownDocument | undefined {
  if (!mayContainMarkdownDocument(source)) return { codeBlocks: [], inlineCodes: [], emphasis: [], characterReferences: [], references: [], definitions: [], prefixes: [], paragraphRanges: [] }
  try {
    return readDocument(source, mathRanges, extensions, prepared)
  } catch {
    // Never let an unverified AST/source mapping expose code to inline parsing.
    // Callers retain the whole original source if the library/adapter rejects it.
    return undefined
  }
}

function readDocument(source: string, mathRanges: EntityRange[], extensions: EntityRange[], prepared?: CodeDocument): MarkdownDocument {
  let syntax = source
  if (extensions.length) {
    const units = source.split("")
    for (const range of extensions) {
      if (range.start === range.end) continue
      units.fill(" ", range.start, range.end)
      // Summary/footer bodies are inline surfaces, even with leading spaces or
      // fence-looking text. A sentinel holds them in paragraph context. Offsets,
      // including UTF-16 surrogate units, stay fixed.
      const lineStart = range.start === 0 || source[range.start - 1] === "\n" || source[range.start - 1] === "\r"
      const lineEnd = range.end === source.length || source[range.end] === "\n" || source[range.end] === "\r"
      if (lineStart && lineEnd) units.fill("\n", range.start, range.end)
      else if (lineStart) units[range.start] = "x"
      else if (lineEnd) units.fill("\n", range.start, range.end)
    }
    syntax = units.join("")
  }
  let document = prepared && !extensions.length ? prepared : parseCodeDocument(syntax)
  const rawPrefixes = document.prefixes
  const opaqueParagraphs = new Map<number, number>()
  const rawNodes: Nodes[] = [document.root]
  while (rawNodes.length) {
    const node = rawNodes.pop()!
    if (node.type === "paragraph" && node.children.every((child) => child.type === "text")) {
      const start = node.position?.start.offset, end = node.position?.end.offset
      if (start !== undefined && end !== undefined) opaqueParagraphs.set(start, end)
    }
    if ("children" in node) for (const child of node.children) rawNodes.push(child)
  }
  const codeRanges = [...document.values.keys()].flatMap((node) => {
    const start = node.position?.start.offset, end = node.position?.end.offset
    return start === undefined || end === undefined ? [] : [{ start, end }]
  })
  // Code wins if it starts before a candidate formula; an earlier formula can
  // contain fake fences. Reparse only that case with the formula made opaque.
  const standaloneMath = (range: EntityRange): boolean => {
    const before = source.slice(Math.max(source.lastIndexOf("\n", range.start - 1), source.lastIndexOf("\r", range.start - 1)) + 1, range.start)
    const after = source.slice(range.end).split(/[\r\n]/, 1)[0] ?? ""
    return source.startsWith("$$", range.start) && /^ {0,3}$/.test(before) && after.trim().length === 0
  }
  // Resolve overlapping opaque candidates in source order. A fake fence inside
  // one formula must not suppress a later formula; math inside real code loses.
  const opaque = [...codeRanges.map((range) => ({ ...range, math: false })), ...mathRanges.map((range) => ({ ...range, math: true }))]
    .sort((a, b) => a.start - b.start || Number(a.math) - Number(b.math))
  const effectiveMath: EntityRange[] = []
  let opaqueEnd = -1
  for (const range of opaque) {
    if (range.start < opaqueEnd) continue
    opaqueEnd = range.end
    if (range.math) effectiveMath.push(range)
  }
  // Completed flow math is already literal data in one paragraph. Reuse that
  // AST; only mixed/inline formulas that could alter flow need a masked reparse.
  const mathToMask = effectiveMath.filter((math) => opaqueParagraphs.get(math.start) !== math.end
    && (/[\r\n|]/.test(source.slice(math.start, math.end)) || standaloneMath(math)))
  if (mathToMask.length) {
    const units = syntax.split("")
    for (const range of mathToMask) {
      units.fill(standaloneMath(range) ? "\n" : "x", range.start, range.end)
    }
    syntax = units.join("")
    document = parseCodeDocument(syntax)
  }
  // A supported style opener on its own line would otherwise start a CommonMark
  // HTML block and hide headings/tables in its body. Only replace tag nodes,
  // never bytes within code/TeX; original UTF-16 positions remain unchanged.
  const styleOpeners: EntityRange[] = []
  const htmlNodes: Nodes[] = [document.root]
  while (htmlNodes.length) {
    const node = htmlNodes.pop()!
    const start = node.position?.start.offset
    if (node.type === "html" && start !== undefined) {
      const tag = inlineStyleTags.find((style) => node.value.startsWith(style.open)
        && /^[\t ]*(?:\r\n|\r|\n|$)/.test(source.slice(start + style.open.length)))
      if (tag) styleOpeners.push({ start, end: start + tag.open.length })
    }
    if ("children" in node) for (const child of node.children) htmlNodes.push(child)
  }
  if (styleOpeners.length) {
    const units = syntax.split("")
    for (const { start, end } of styleOpeners) units.fill("x", start, end)
    document = parseCodeDocument(units.join(""))
  }
  const codeBlocks: MarkdownCodeBlock[] = []
  const definitions: EntityRange[] = []
  const paragraphRanges: EntityRange[] = []
  const inlineRanges: EntityRange[] = []
  const definitionsByID = new Map<string, Definition>()
  const referenceNodes: (LinkReference | ImageReference | Link)[] = []
  const blockImages = new Set<ImageReference>()
  // GFM ends a bare autolink before a trailing &name; token, whereas Inline's
  // existing URL detector includes those bytes. Preserve that URL contract;
  // explicit [labels] still decode their text normally.
  const literalURLs = new Map<number, EntityRange>(document.characterReferences.length ? urlEntities(source)
    .map((url) => [Number(url.offset), { start: Number(url.offset), end: Number(url.offset + url.length) }]) : [])
  const protectedReferences: EntityRange[] = [...effectiveMath]
  const pending: { node: Nodes; inlineStart?: number }[] = [{ node: document.root }]
  while (pending.length) {
    const { node, inlineStart } = pending.pop()!
    if (node.type === "link") {
      const start = node.position?.start.offset, url = start === undefined ? undefined : literalURLs.get(start)
      if (url) protectedReferences.push(url)
    }
    if (node.type === "paragraph" || node.type === "heading") {
      const start = node.position?.start.offset, end = node.position?.end.offset
      if (start !== undefined && end !== undefined) paragraphRanges.push({ start, end })
    }
    if (node.type === "paragraph" || node.type === "heading" || node.type === "tableCell") {
      const start = node.position?.start.offset, end = node.position?.end.offset
      if (start !== undefined && end !== undefined) inlineRanges.push({ start: inlineStart ?? start, end })
    }
    if (node.type === "code") {
      const start = node.position?.start.offset, end = node.position?.end.offset
      if (start === undefined || end === undefined) throw new Error("Missing Markdown code position")
      const mapped = mapCode(source, node, document.values.get(node) ?? [], start, end)
      if (!mapped) throw new Error("Unverified Markdown code source map")
      codeBlocks.push(mapped)
    } else if (node.type === "definition") {
      const start = node.position?.start.offset, end = node.position?.end.offset
      if (start === undefined || end === undefined) throw new Error("Missing Markdown definition position")
      definitions.push({ start, end })
      if (!definitionsByID.has(node.identifier)) definitionsByID.set(node.identifier, node)
    }
    if (node.type === "linkReference" || node.type === "imageReference") referenceNodes.push(node)
    if (node.type === "link" && node.position && node.position.start.line !== node.position.end.line) referenceNodes.push(node)
    if (node.type === "paragraph") for (const child of node.children) {
      if (child.type === "imageReference") blockImages.add(child)
    }
    if ("children" in node) {
      for (let index = node.children.length - 1; index >= 0; index--) pending.push({ node: node.children[index]!,
        // Preserve the compatibility parser's single-line padded *italic*
        // syntax, which CommonMark otherwise reads as a list marker.
        inlineStart: node.type === "listItem" && index === 0 ? node.position?.start.offset : undefined })
    }
  }
  const references: MarkdownReference[] = referenceNodes.filter((node) => !effectiveMath.some((range) =>
    range.start <= (node.position?.start.offset ?? -1) && (node.position?.start.offset ?? -1) < range.end)).map((node) => {
    const start = node.position?.start.offset, end = node.position?.end.offset
    const target = node.type === "link" ? node : definitionsByID.get(node.identifier)
    if (start === undefined || end === undefined || !target) throw new Error("Unresolved Markdown reference")
    const image = node.type === "imageReference"
    const labelStart = start + (image ? 2 : 1)
    const labelEnd = linkLabelEnd(source, labelStart - 1)
    if (labelEnd === undefined || labelEnd >= end) throw new Error("Unverified Markdown reference label")
    return { start, end, labelStart, labelEnd, url: target.url, image,
      blockImage: node.type === "imageReference" && blockImages.has(node) }
  })
  const prefixes: EntityRange[] = document.prefixes.filter((prefix) => prefix.inline
    && !effectiveMath.some((math) => math.start <= prefix.start && prefix.start < math.end))
  const mathPrefixes = rawPrefixes.filter((prefix) => prefix.kind !== "linePrefix" && prefix.containerStart >= 0
    && effectiveMath.some((math) => prefix.containerStart < math.start && math.start <= prefix.start && prefix.end <= math.end))
  prefixes.push(...mathPrefixes)
  // Leading indentation belongs to a container only when followed by a real
  // container prefix. Preserve indentation and `>` operators within TeX itself.
  for (const prefix of rawPrefixes) {
    if (prefix.kind === "linePrefix" && mathPrefixes.some((next) => next.start === prefix.end)) prefixes.push(prefix)
  }
  protectedReferences.sort((a, b) => a.start - b.start || b.end - a.end)
  let protectedReferenceIndex = 0
  const characterReferences = document.characterReferences.filter((span) => {
    while (protectedReferences[protectedReferenceIndex] && protectedReferences[protectedReferenceIndex]!.end <= span.start) protectedReferenceIndex++
    const protectedRange = protectedReferences[protectedReferenceIndex]
    return !protectedRange || protectedRange.start > span.start
  })
  return { codeBlocks, inlineCodes: collectInlineCodes(source, document), emphasis: collectEmphasis(source, document.root), characterReferences,
    definitions, references, root: document.root, paragraphRanges, inlineRanges,
    prefixes: prefixes.filter((prefix) => prefix.start < prefix.end
      && !codeBlocks.some((code) => prefix.start < code.end && code.start < prefix.end))
      .map(({ start, end }) => ({ start, end })).sort((a, b) => a.start - b.start || a.end - b.end) }
}

function parseCodeDocument(source: string): CodeDocument {
  const values = new Map<Code | InlineCode, CodeValue[]>()
  const prefixes: Prefix[] = []
  const characterReferences: MarkdownCharacterReference[] = []
  let line = -1, quoteIndex = 0, listIndex = 0
  const capturePrefix: Handle = function(token) {
    if (token.start.line !== line) { line = token.start.line; quoteIndex = 0; listIndex = 0 }
    const quotes = this.stack.filter((node) => node.type === "blockquote")
    const lists = this.stack.filter((node) => node.type === "listItem")
    let containerStart = -1
    if (token.type === "blockQuotePrefix") containerStart = quotes[quoteIndex++]?.position?.start.offset ?? -1
    else if (token.type === "listItemPrefix" || token.type === "listItemIndent") {
      containerStart = lists[listIndex++]?.position?.start.offset ?? -1
      if (token.type === "listItemPrefix") return
    }
    if (token.type !== "linePrefix" && token.type !== "blockQuotePrefix" && token.type !== "listItemIndent") return
    const block = this.stack.findLast((node) => node.type === "paragraph" || node.type === "heading")
    const inline = (quotes.length > 0 || lists.length > 0) && !this.stack.some((node) => node.type === "code")
      && block?.position !== undefined && block.position.start.line < token.start.line
    prefixes.push({ start: token.start.offset, end: token.end.offset, kind: token.type, containerStart, inline })
  }
  const captureInline: Handle = function(token) {
    const code = this.stack.findLast((node): node is InlineCode => node.type === "inlineCode")
    if (code) {
      const spans = values.get(code) ?? []
      if (token.type !== "codeTextSequence") spans.push({ start: token.start.offset, end: token.end.offset, value: this.sliceSerialize(token),
        padding: token.type === "codeTextPadding" })
      values.set(code, spans)
    }
    // codeTextData normally uses the generic data handler. Padding has no
    // default handler; retain it only in our source-preserving code projection.
    if (token.type === "codeTextData") this.config.exit["data"]!.call(this, token)
  }
  // Public mdast compile hook. Retain the default text accumulation exactly,
  // while capturing micromark's source positions (including partial tabs).
  const capture: Extension = { enter: {
    characterReference(token) {
      // The normal character-reference enter handler is the data handler.
      // Keep mdast's decoding/accumulation while retaining the verified source
      // token; code, TeX, HTML attributes and autolinks do not emit this token.
      this.config.enter["data"]!.call(this, token)
      const content = decodeString(this.sliceSerialize(token))
      characterReferences.push({ start: token.start.offset, end: token.end.offset, content })
    },
  }, exit: {
    blockQuotePrefix: capturePrefix, listItemIndent: capturePrefix, listItemPrefix: capturePrefix, linePrefix: capturePrefix,
    codeTextData: captureInline, codeTextPadding: captureInline, codeTextSequence: captureInline,
    codeFlowValue(token) {
    const value = this.sliceSerialize(token)
    const tail = this.stack.pop()
    if (tail?.type !== "text" || !tail.position) throw new Error("Invalid Markdown code token")
    tail.value += value
    tail.position.end = { line: token.end.line, column: token.end.column, offset: token.end.offset }
    const code = this.stack.findLast((node): node is Code => node.type === "code")
    if (code) {
      const spans = values.get(code) ?? []
      spans.push({ start: token.start.offset, end: token.end.offset, value })
      values.set(code, spans)
    }
  } } }
  return { root: richMarkdownAst(source, [capture]), values, prefixes, characterReferences }
}

function mapInlineCode(source: string, node: InlineCode, values: CodeValue[], start: number, end: number): MarkdownInlineCode | undefined {
  let openingEnd = start
  while (source[openingEnd] === "`") openingEnd++
  const closingStart = end - (openingEnd - start)
  if (closingStart < openingEnd || source.slice(closingStart, end) !== source.slice(start, openingEnd)) return undefined
  const sourceToContent = Array<number>(end - start + 1).fill(0)
  let cursor = openingEnd, content = "", astValue = ""
  const append = (lower: number, upper: number, value: string, padding = false): boolean => {
    const raw = source.slice(lower, upper), virtual = value.length - raw.length
    if (virtual < 0 || virtual > 3 || value.slice(0, virtual) !== " ".repeat(virtual)
      || value.slice(virtual) !== raw.replaceAll("\0", "\uFFFD")) return false
    sourceToContent.fill(content.length, cursor - start, lower - start + 1)
    content += " ".repeat(virtual)
    for (let index = lower; index <= upper; index++) sourceToContent[index - start] = content.length + index - lower
    content += raw
    if (!padding) astValue += value
    cursor = upper
    return true
  }
  const appendBreaks = (upper: number): boolean => {
    const base = cursor
    for (const match of source.slice(base, upper).matchAll(/\r\n|\r|\n/g)) {
      // Keep a stable base: append advances cursor while match.index is local
      // to the original gap string.
      const lower = base + match.index
      if (!append(lower, lower + match[0].length, match[0])) return false
    }
    return true
  }
  for (const value of values) {
    if (!appendBreaks(value.start) || !append(value.start, value.end, value.value, value.padding)) return undefined
  }
  if (!appendBreaks(closingStart) || astValue !== node.value) return undefined
  sourceToContent.fill(content.length, cursor - start)
  return { start, end, content, sourceToContent }
}

function mapCode(source: string, node: Code, values: CodeValue[], start: number, end: number): MarkdownCodeBlock | undefined {
  const sourceToContent = Array<number>(end - start + 1).fill(0)
  let cursor = start, content = ""
  const append = (lower: number, upper: number, value: string): boolean => {
    const raw = source.slice(lower, upper)
    const virtual = value.length - raw.length
    // micromark may supply up to three virtual spaces from a consumed tab.
    // It also replaces NUL with U+FFFD; retain the original code byte instead.
    if (virtual < 0 || virtual > 3 || value.slice(0, virtual) !== " ".repeat(virtual)
      || value.slice(virtual) !== raw.replaceAll("\0", "\uFFFD")) return false
    sourceToContent.fill(content.length, cursor - start, lower - start + 1)
    content += " ".repeat(virtual)
    for (let index = lower; index <= upper; index++) sourceToContent[index - start] = content.length + index - lower
    content += raw
    cursor = upper
    return true
  }
  const lineEndings = (lower: number, upper: number): CodeValue[] => {
    const result: CodeValue[] = []
    for (const match of source.slice(lower, upper).matchAll(/\r\n|\r|\n/g)) {
      result.push({ start: lower + match.index, end: lower + match.index + match[0].length, value: match[0] })
    }
    return result
  }
  const fenced = source[start] === "`" || source[start] === "~"
  for (let index = 0; index < values.length; index++) {
    const value = values[index]!
    let breaks = lineEndings(cursor, value.start)
    if (index === 0 && fenced) breaks = breaks.slice(1) // opening fence line
    for (const gap of breaks) if (!append(gap.start, gap.end, gap.value)) return undefined
    if (!append(value.start, value.end, value.value)) return undefined
  }
  const remainder = node.value.slice(content.length)
  if (!/^[\r\n]*$/.test(remainder)) return undefined
  let trailing = lineEndings(cursor, end)
  if (!values.length && fenced) trailing = trailing.slice(1)
  for (const gap of trailing) {
    if (content.length >= node.value.length) break
    if (!append(gap.start, gap.end, gap.value)) return undefined
  }
  if (content.replaceAll("\0", "\uFFFD") !== node.value) return undefined
  sourceToContent.fill(content.length, cursor - start)
  return { start, end, content, sourceToContent, language: cleanFenceLanguage(node.lang ?? "") }
}
