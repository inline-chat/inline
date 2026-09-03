import { MessageEntity, MessageEntity_Type } from "@inline-chat/protocol/core"
import { isMarkdownEscapable } from "../translation2/entities/escape"
import { additionalInlineStyles, literalHTMLTokenEnd, maxInlineStyleDepth, readInlineStyle, readPaddedEmphasis } from "../translation2/entities/inlineStyles"
import { mathLimits, readMathCandidate } from "../translation2/entities/math"
import { urlEntities } from "../translation2/entities/url"
import { linkLabelEnd, readInlineLinkDestination } from "../translation2/entities/linkSyntax"
import { isClosingFence, parseOpeningFence, readFencedCode, readLine, type MarkdownFence } from "../translation2/entities/fences"
import type { EntityRange } from "../translation2/entities/types"
import { hasVisibleMarkdownContent, markdownDocument, mayContainMarkdownDocument, prepareMarkdownInlineSyntax, relativeInlineCodes, relativeEmphasis, relativeInlineRanges, relativeCharacterReferences, inlineRangeEnd,
  type MarkdownDocument, type MarkdownCharacterReference, type MarkdownEmphasis, type MarkdownInlineCode, type MarkdownReference } from "./markdownDocument"
import { removeSourceRanges, sourceRangesWithin } from "./markdownSourceMap"

export type ParsedMarkdown = {
  text: string
  entities: MessageEntity[]
}

export type ParsedMarkdownWithSourceMap = ParsedMarkdown & {
  /** UTF-16 source boundary to UTF-16 output boundary, including the final boundary. */
  sourceToOutput: number[]
  /** Revision-local source spans, including oversized formulas kept literal. */
  mathRanges?: EntityRange[]
  /** CommonMark code whose body is not a contiguous source slice. */
  codeRanges?: EntityRange[]
  /** Ephemeral AST shared with the block projection; never persisted. */
  document?: MarkdownDocument
}

type Match = {
  start: number
  end: number
  content: string
  type?: MessageEntity_Type
  url?: string
  language?: string
  nestedEntities?: MessageEntity[]
  contentStart: number
  contentEnd: number
  nestedSourceToOutput?: number[]
  opaque?: boolean
  mathRanges?: EntityRange[]
  blockExtension?: boolean
}

/**
 * Parses markdown text and extracts entities.
 * Supported patterns: bold, italic, inline code, code blocks, links, and
 * CommonMark backslash escapes.
 */
export function parseMarkdown(input: string): ParsedMarkdown {
  const { text, entities } = parseMarkdownWithSourceMap(input)
  return { text, entities }
}

/**
 * Repairs a narrow gateway progress annotation before Markdown parsing.
 *
 * Hermes collapses repeated terminal progress by appending ` (×N)` to the
 * entire fenced fragment. That leaves the counter after the closing delimiter,
 * which CommonMark interprets as a new opening fence. Replace only that one
 * separator while a matching fence is open; the counter remains visible on the
 * following line and source length stays unchanged for UTF-16 range mapping.
 */
export function normalizeMarkdownInput(input: string): string {
  if (!input.includes("(×")) return input

  // This repair is only for Markdown fences. TeX and link bodies can contain
  // identical text and must retain their exact source. Avoid recursive labels
  // while collecting the outer opaque spans for this uncommon normalization.
  const syntax: Match[] = []
  const prepared = prepareMarkdownInlineSyntax(input)
  if (!prepared) return input
  findInlineSyntax(input, syntax, maxInlineStyleDepth, [], prepared.inlineCodes, prepared.emphasis)
  const opaque = opaqueInlineMatches(syntax)
  let opaqueIndex = 0
  const output: string[] = []
  let cursor = 0
  let fence: MarkdownFence | undefined

  while (cursor < input.length) {
    const line = readLine(input, cursor)
    let value = line.value
    while (opaque[opaqueIndex] && opaque[opaqueIndex]!.end <= cursor) opaqueIndex++
    const protectedLine = opaque[opaqueIndex] && opaque[opaqueIndex]!.start <= cursor

    if (protectedLine) {
      // Leave both source and the surrounding Markdown fence state untouched.
    } else if (fence) {
      const normalizedClose = normalizeRepeatedClosingFence(value, fence)
      if (normalizedClose !== undefined) {
        value = normalizedClose
        fence = undefined
      } else if (isClosingFence(value, fence)) {
        fence = undefined
      }
    } else {
      fence = parseOpeningFence(value)
    }

    output.push(value, input.slice(line.contentEnd, line.next))
    cursor = line.next
  }

  return output.join("")
}

/** Internal compatibility parser result used to map structural Markdown ranges. */
export function parseMarkdownWithSourceMap(input: string): ParsedMarkdownWithSourceMap {
  return parseMarkdownAtDepth(input, 0)
}

/** Shared block grammar for the translation transport. No message-only tags or
 * gateway normalization are applied. Labels contribute opaque math ranges. */
export function parseMarkdownDocument(input: string): MarkdownDocument | undefined {
  if (!mayContainMarkdownDocument(input)) return { codeBlocks: [], inlineCodes: [], emphasis: [], characterReferences: [], references: [], definitions: [], prefixes: [], paragraphRanges: [] }
  const syntax: Match[] = []
  const prepared = prepareMarkdownInlineSyntax(input)
  if (!prepared) return undefined
  findInlineSyntax(input, syntax, 0, [], prepared.inlineCodes, prepared.emphasis)
  return buildDocument(input, syntax, prepared.syntax)
}

function buildDocument(input: string, matches: Match[], prepared?: Parameters<typeof markdownDocument>[3]): MarkdownDocument | undefined {
  const document = markdownDocument(input, matches.flatMap((match) => match.mathRanges ?? []),
    matches.filter((match) => match.blockExtension), prepared)
  if (!document) return undefined
  // Keep existing root-fence trimming/translation whitespace behavior.
  document.codeBlocks = document.codeBlocks.filter((code) => !matches.some((match) => match.type === MessageEntity_Type.PRE
    && match.start === code.start && match.end === code.end))
  return document
}

function parseMarkdownAtDepth(input: string, depth: number, references: MarkdownReference[] = [], inlineCodes: MarkdownInlineCode[] = [], emphasis: MarkdownEmphasis[] = [], inlineRanges?: EntityRange[], characterReferences: MarkdownCharacterReference[] = []): ParsedMarkdownWithSourceMap {
  if (depth === 0) input = normalizeMarkdownInput(input)
  if (!input) {
    return { text: "", entities: [], sourceToOutput: [0] }
  }
  if (depth >= maxInlineStyleDepth) {
    return { text: input, entities: [], sourceToOutput: Array.from({ length: input.length + 1 }, (_, index) => index) }
  }

  // Find all matches first, then process in order
  const matches: Match[] = []
  const prepared = depth === 0 ? prepareMarkdownInlineSyntax(input) : { inlineCodes, emphasis, syntax: undefined }
  if (!prepared) return { text: input, entities: [], sourceToOutput: Array.from({ length: input.length + 1 }, (_, index) => index) }
  inlineCodes = prepared.inlineCodes
  emphasis = prepared.emphasis

  // Backslash escapes consume the slash and protect the escaped punctuation
  // from lower-priority structural matches.
  findEscapes(input, matches)

  // Visit opaque syntax in source order. A backtick or link-looking fragment
  // inside TeX must not consume later Markdown, and code/link destinations must
  // not expose dollar markers to the math parser.
  findInlineSyntax(input, matches, depth, references, inlineCodes, emphasis, inlineRanges, characterReferences)
  // Resolve structural extensions after opaque spans are known so tags inside
  // a formula cannot change indentation or disclosure state outside it.
  if (depth === 0) findBlockExtensionSyntax(input, matches)
  const document = depth === 0 ? buildDocument(input, matches, prepared.syntax) : { codeBlocks: [], inlineCodes, emphasis, inlineRanges, characterReferences, definitions: [], references, prefixes: [], paragraphRanges: [] }
  if (!document) {
    return { text: input, entities: [], sourceToOutput: Array.from({ length: input.length + 1 }, (_, index) => index) }
  }
  const codeBlocks = document.codeBlocks
  references = document.references
  if (document.inlineCodes.length !== inlineCodes.length || document.inlineCodes.some((code, index) =>
    code.start !== inlineCodes[index]?.start || code.end !== inlineCodes[index]?.end || code.content !== inlineCodes[index]?.content)
    || document.inlineRanges !== inlineRanges || document.emphasis.length !== emphasis.length || document.emphasis.some((span, index) =>
      span.start !== emphasis[index]?.start || span.end !== emphasis[index]?.end)) {
    // Final document scopes can reject a cross-cell link, or extension masking
    // can reveal code previously treated as HTML. Rescan only changed context.
    matches.length = 0
    findEscapes(input, matches)
    findInlineSyntax(input, matches, depth, references, document.inlineCodes, document.emphasis, document.inlineRanges, document.characterReferences)
    if (depth === 0) findBlockExtensionSyntax(input, matches)
  }
  inlineCodes = document.inlineCodes
  emphasis = document.emphasis
  inlineRanges = document.inlineRanges
  characterReferences = document.characterReferences
  for (const span of characterReferences) matches.push({
    ...span, contentStart: span.start, contentEnd: span.end,
    nestedSourceToOutput: [...Array<number>(span.end - span.start).fill(0), span.content.length],
  })
  for (const code of codeBlocks) {
    // Code is opaque even if the initial inline scan saw escapes, math or links
    // inside it. Container prefixes are removed only by micromark's source map.
    for (let index = matches.length - 1; index >= 0; index--) {
      const match = matches[index]!
      if (match.start < code.end && code.start < match.end) matches.splice(index, 1)
    }
    matches.push({ ...code, type: MessageEntity_Type.PRE, contentStart: code.start, contentEnd: code.end,
      nestedSourceToOutput: code.sourceToContent })
  }
  for (const definition of document.definitions) {
    for (let index = matches.length - 1; index >= 0; index--) {
      const match = matches[index]!
      if (match.start < definition.end && definition.start < match.end) matches.splice(index, 1)
    }
    matches.push({ ...definition, content: "", contentStart: definition.end, contentEnd: definition.end, opaque: true })
  }
  // The scoped rescan already rebuilt inline links with final reference and
  // child metadata. Do not recursively parse every label a third time here.
  for (const reference of references) matches.push(referenceMatch(input, reference, depth, references, inlineCodes, emphasis, inlineRanges, characterReferences))
  const emphasisMatches = findEmphasis(input, depth, references, inlineCodes, emphasis, inlineRanges, characterReferences)
  matches.push(...emphasisMatches)
  const formatSyntax = maskInlineBoundaries(maskOpaqueBodies(input, matches, emphasisMatches), inlineRanges)

  // 4. Emails: example@domain.com
  findEmails(input, matches)

  findCompatibilityEmphasis(input, matches, depth, formatSyntax, references, inlineCodes, emphasis, inlineRanges, characterReferences)
  findAdditionalStyles(input, matches, depth, references, inlineCodes, emphasis, inlineRanges, characterReferences)

  // Remove overlapping matches (earlier patterns win)
  const filteredMatches = removeOverlaps(matches.filter((match) =>
    // Disclosure indentation is a flat fallback marker, not paragraph content.
    // Keep it on the first line only; continuation lines share one text range.
    !(match.blockExtension && match.start === match.end && document.paragraphRanges.some((range) =>
      range.start < match.start && match.start < range.end))
    && (match.type === MessageEntity_Type.PRE
      || !codeBlocks.some((code) => match.start < code.start && code.start < match.end))))

  // Sort by start position
  filteredMatches.sort((a, b) => a.start - b.start)

  // Build output text and entities
  let result = ""
  let lastIndex = 0
  const entities: MessageEntity[] = []
  const mathRanges: EntityRange[] = []
  const sourceToOutput = Array<number>(input.length + 1).fill(0)

  for (const match of filteredMatches) {
    mathRanges.push(...(match.mathRanges ?? []))
    // Add text before this match
    mapLiteralBoundaries(sourceToOutput, lastIndex, match.start, result.length)
    result += input.slice(lastIndex, match.start)

    const outputStart = result.length
    fillCollapsedBoundaries(sourceToOutput, match.start, match.contentStart, outputStart)

    // Only create entity if there's actual content
    if (match.content.length > 0) {
      // Record entity with offset in output text
      const offset = result.length
      if (match.type !== undefined) {
        entities.push(createEntity(match, offset, match.type))
      }
      if (match.nestedEntities?.length) {
        entities.push(...shiftEntities(match.nestedEntities, offset))
      }
    }
    // Empty code blocks also collapse every interior boundary at this offset.
    if (match.nestedSourceToOutput) {
      for (let index = 0; index < match.nestedSourceToOutput.length; index++) {
        sourceToOutput[match.contentStart + index] = outputStart + match.nestedSourceToOutput[index]!
      }
    } else {
      mapLiteralBoundaries(sourceToOutput, match.contentStart, match.contentEnd, outputStart)
    }
    result += match.content
    fillCollapsedBoundaries(sourceToOutput, match.contentEnd, match.end, result.length)
    // Always consume the matched syntax
    lastIndex = match.end
  }

  // Add remaining text
  mapLiteralBoundaries(sourceToOutput, lastIndex, input.length, result.length)
  result += input.slice(lastIndex)

  // Do not turn a formerly visible definition-only message into an empty row.
  if (document.definitions.length && (result.trim().length === 0 || (!mathRanges.length && !hasVisibleMarkdownContent(document)))) {
    return { text: input, entities: [], sourceToOutput: Array.from({ length: input.length + 1 }, (_, index) => index) }
  }
  // Apply container punctuation removal after nested inline parsing so links,
  // formatting, math, and explicit client entities all share the same map.
  const prefixOutputs = document.prefixes.map((range) => ({
    start: sourceToOutput[range.start]!, end: sourceToOutput[range.end]!,
  }))
  // Code's verified map may already have removed every continuation prefix.
  const projected = prefixOutputs.some((range) => range.end > range.start) ? removeSourceRanges(result, prefixOutputs) : undefined
  const projectedEntities = projected ? entities.flatMap((entity) => {
    const start = projected.sourceToOutput[Number(entity.offset)]!
    const end = projected.sourceToOutput[Number(entity.offset + entity.length)]!
    return end > start ? [{ ...entity, offset: BigInt(start), length: BigInt(end - start) }] : []
  }) : entities
  return { text: projected?.text ?? result, entities: projectedEntities,
    sourceToOutput: projected ? sourceToOutput.map((boundary) => projected.sourceToOutput[boundary]!) : sourceToOutput, mathRanges,
    codeRanges: codeBlocks.map(({ start, end }) => ({ start, end })), document: depth === 0 ? document : undefined }
}

export function mathOutputRanges(parsed: ParsedMarkdownWithSourceMap): EntityRange[] {
  return (parsed.mathRanges ?? []).flatMap((range) => {
    const start = parsed.sourceToOutput[range.start]
    const end = parsed.sourceToOutput[range.end]
    return start !== undefined && end !== undefined && end > start ? [{ start, end }] : []
  })
}

function shiftedMathRanges(parsed: ParsedMarkdownWithSourceMap, offset: number): EntityRange[] {
  return (parsed.mathRanges ?? []).map((range) => ({ start: range.start + offset, end: range.end + offset }))
}

function findBlockExtensionSyntax(text: string, matches: Match[]): void {
  const opaque = opaqueInlineMatches(matches)
  let opaqueIndex = 0
  let cursor = 0
  let detailsDepth = 0
  let fence: MarkdownFence | undefined

  const remove = (start: number, end: number, replacement = ""): void => {
    matches.push({ start, end, content: replacement, contentStart: end, contentEnd: end, blockExtension: true })
  }

  while (cursor < text.length) {
    const line = readLine(text, cursor)
    while (opaque[opaqueIndex] && opaque[opaqueIndex]!.end <= cursor) opaqueIndex++
    if (opaque[opaqueIndex] && opaque[opaqueIndex]!.start <= cursor) {
      cursor = line.next
      continue
    }
    if (fence) {
      if (isClosingFence(line.value, fence)) fence = undefined
      cursor = line.next
      continue
    }

    const openingFence = parseOpeningFence(line.value)
    if (openingFence) {
      if (detailsDepth > 0) remove(line.start, line.start, "\t".repeat(detailsDepth))
      fence = openingFence
      cursor = line.next
      continue
    }

    if (/^<details(?: open)?>$/.test(line.value)) {
      const summaryLine = line.next < text.length ? readLine(text, line.next) : undefined
      const hasCompleteSummary = summaryLine
        ? /^<summary(?: kind="progress")?(?: activity="(?:reasoning|explore|read|search|edit|delete|move|command|web|tool)")?>.*<\/summary>$/.test(summaryLine.value)
        : false
      if (!hasCompleteSummary) {
        cursor = line.next
        continue
      }
      remove(line.start, line.contentEnd)
      detailsDepth += 1
      cursor = line.next
      continue
    }

    if (line.value === "</details>" && detailsDepth > 0) {
      detailsDepth -= 1
      remove(line.start, line.contentEnd)
      cursor = line.next
      continue
    }

    const summary = /^<summary(?: kind="progress")?(?: activity="(?:reasoning|explore|read|search|edit|delete|move|command|web|tool)")?>(.*)<\/summary>$/.exec(line.value)
    if (summary && detailsDepth > 0) {
      const openingEnd = line.start + line.value.indexOf(">") + 1
      const closingStart = line.contentEnd - "</summary>".length
      remove(line.start, openingEnd, `${"\t".repeat(Math.max(0, detailsDepth - 1))}▸ `)
      remove(closingStart, line.contentEnd)
      cursor = line.next
      continue
    }

    const footer = /^<footer>(.*)<\/footer>$/.exec(line.value)
    if (footer) {
      const openingEnd = line.start + "<footer>".length
      const closingStart = line.contentEnd - "</footer>".length
      remove(line.start, openingEnd, "\t".repeat(detailsDepth))
      remove(closingStart, line.contentEnd)
      cursor = line.next
      continue
    }

    if (detailsDepth > 0 && line.value.trim().length > 0) {
      remove(line.start, line.start, "\t".repeat(detailsDepth))
    }
    cursor = line.next
  }
}

function opaqueInlineMatches(matches: Match[]): Match[] {
  return matches.filter((match) => match.opaque || match.type === MessageEntity_Type.MATH
    || match.type === MessageEntity_Type.CODE || match.type === MessageEntity_Type.TEXT_URL)
    .sort((a, b) => a.start - b.start)
}

function mapLiteralBoundaries(map: number[], sourceStart: number, sourceEnd: number, outputStart: number): void {
  for (let boundary = sourceStart; boundary <= sourceEnd; boundary++) {
    map[boundary] = outputStart + boundary - sourceStart
  }
}

function fillCollapsedBoundaries(map: number[], sourceStart: number, sourceEnd: number, output: number): void {
  for (let boundary = sourceStart; boundary <= sourceEnd; boundary++) {
    map[boundary] = output
  }
}

function shiftEntities(entities: MessageEntity[], offset: number): MessageEntity[] {
  return entities.map((entity) => ({
    ...entity,
    offset: entity.offset + BigInt(offset),
  }))
}

function parseNestedContent(
  content: string,
  depth: number,
  options?: { allowedTypes?: Set<MessageEntity_Type>; references?: MarkdownReference[]; inlineCodes?: MarkdownInlineCode[]; emphasis?: MarkdownEmphasis[]; inlineRanges?: EntityRange[]; characterReferences?: MarkdownCharacterReference[] }
): ParsedMarkdownWithSourceMap {
  const parsed = parseMarkdownAtDepth(content, depth + 1, options?.references, options?.inlineCodes, options?.emphasis, options?.inlineRanges, options?.characterReferences)

  if (!options?.allowedTypes) {
    return parsed
  }

  return {
    text: parsed.text,
    entities: parsed.entities.filter((entity) => options.allowedTypes?.has(entity.type)),
    sourceToOutput: parsed.sourceToOutput,
    mathRanges: parsed.mathRanges,
  }
}

function createEntity(match: Match, offset: number, type: MessageEntity_Type): MessageEntity {
  const entity: MessageEntity = {
    offset: BigInt(offset),
    length: BigInt(match.content.length),
    type,
    entity: { oneofKind: undefined },
  }

  if (type === MessageEntity_Type.TEXT_URL && match.url) {
    entity.entity = {
      oneofKind: "textUrl",
      textUrl: { url: match.url },
    }
  } else if (type === MessageEntity_Type.PRE && match.language !== undefined) {
    entity.entity = {
      oneofKind: "pre",
      pre: { language: match.language },
    }
  }

  return entity
}

function removeOverlaps(matches: Match[]): Match[] {
  // Sort by start position, then by priority (earlier in array = higher priority)
  const sorted = [...matches].sort((a, b) => a.start - b.start)

  const result: Match[] = []
  let lastEnd = -1

  for (const match of sorted) {
    // Skip if this match overlaps with a previous one
    if (match.start < lastEnd) {
      continue
    }
    result.push(match)
    lastEnd = match.end
  }

  return result
}

function findInlineSyntax(text: string, matches: Match[], depth: number, references: MarkdownReference[] = [], inlineCodes: MarkdownInlineCode[] = [], emphasis: MarkdownEmphasis[] = [], inlineRanges?: EntityRange[], characterReferences: MarkdownCharacterReference[] = []): void {
  // Dollar characters in existing literal URLs are URL bytes, not math delimiters.
  const literalURLs = text.includes("$") ? urlEntities(text).map((url) => ({
    start: Number(url.offset), end: Number(url.offset + url.length),
  })) : []
  let urlIndex = 0
  let codeIndex = 0
  for (let cursor = 0; cursor < text.length; ) {
    while (inlineCodes[codeIndex] && inlineCodes[codeIndex]!.end <= cursor) codeIndex++
    const mappedCode = inlineCodes[codeIndex]
    // Removing a surrounding label/style can move inline backticks to column
    // zero. Their original document context still wins over the fence scanner.
    if (mappedCode?.start === cursor) {
      matches.push({ ...mappedCode, type: MessageEntity_Type.CODE, contentStart: mappedCode.start, contentEnd: mappedCode.end,
        nestedSourceToOutput: mappedCode.sourceToContent, opaque: true })
      cursor = mappedCode.end
      continue
    }
    if (cursor === 0 || text[cursor - 1] === "\n") {
      const fence = readFencedCode(text, cursor)
      if (fence) {
        const raw = text.slice(fence.contentStart, fence.contentEnd)
        const content = raw.trim()
        const contentStart = fence.contentStart + raw.length - raw.trimStart().length
        const contentEnd = contentStart + content.length
        matches.push({ ...fence, content, contentStart, contentEnd, type: MessageEntity_Type.PRE })
        cursor = fence.end
        continue
      }
    }
    if (text[cursor] === "\\" && isMarkdownEscapable(text[cursor + 1])) { cursor += 2; continue }
    const htmlEnd = literalHTMLTokenEnd(text, cursor)
    if (htmlEnd !== undefined) {
      matches.push({ start: cursor, end: htmlEnd, content: text.slice(cursor, htmlEnd), contentStart: cursor, contentEnd: htmlEnd, opaque: true })
      cursor = htmlEnd
      continue
    }
    const code = text[cursor] === "`" ? readInlineCode(text, cursor, inlineRangeEnd(inlineRanges, cursor, text.length)) : undefined
    const link = !code && text[cursor] === "[" ? readLink(text, cursor, depth, references, inlineCodes, emphasis, inlineRanges, characterReferences) : undefined
    if (code || link) {
      const match = (code ?? link)!
      matches.push(match)
      cursor = match.end
      continue
    }
    while (literalURLs[urlIndex] && literalURLs[urlIndex]!.end <= cursor) urlIndex++
    const math = text[cursor] === "$"
      && !(literalURLs[urlIndex] && literalURLs[urlIndex]!.start <= cursor)
      && readMathCandidate(text, cursor)
    if (math) {
      const withinLimit = math.contentEnd - math.contentStart <= (math.display ? mathLimits.displaySource : mathLimits.inlineSource)
      matches.push({
        start: cursor, end: math.end,
        contentStart: withinLimit ? math.contentStart : cursor, contentEnd: withinLimit ? math.contentEnd : math.end,
        content: withinLimit ? text.slice(math.contentStart, math.contentEnd) : text.slice(cursor, math.end),
        type: withinLimit ? MessageEntity_Type.MATH : undefined,
        opaque: true,
        mathRanges: [{ start: cursor, end: math.end }],
      })
      cursor = math.end
      continue
    }
    // An unmatched backtick run is a single literal token, not many openers.
    cursor += text[cursor] === "`" ? backtickRunLength(text, cursor) : 1
  }
}

function maskOpaqueBodies(text: string, matches: Match[], formatting: EntityRange[] = []): string {
  const ranges: EntityRange[] = matches.filter((match) => match.opaque || match.type === MessageEntity_Type.MATH
    || match.type === MessageEntity_Type.CODE || match.type === MessageEntity_Type.PRE
    || match.type === MessageEntity_Type.TEXT_URL)
  ranges.push(...formatting)
  ranges.sort((a, b) => a.start - b.start || b.end - a.end)
  if (ranges.length === 0) return text
  let result = ""
  let cursor = 0
  for (const range of ranges) {
    if (range.end <= cursor) continue
    result += text.slice(cursor, Math.max(cursor, range.start))
    result += text.slice(Math.max(cursor, range.start), range.end).replace(/[^\r\n]/g, "x")
    cursor = range.end
  }
  return result + text.slice(cursor)
}

function maskInlineBoundaries(text: string, ranges: EntityRange[] | undefined): string {
  if (!ranges) return text
  const boundaries = ranges.filter((range) => range.end < text.length && text[range.end] !== "\r" && text[range.end] !== "\n")
  if (!boundaries.length) return text
  const units = text.split("")
  // Recognition only: source slices and UTF-16 maps still use the original
  // bytes. A table-cell separator cannot pair two compatibility delimiters.
  for (const range of boundaries) units[range.end] = "\n"
  return units.join("")
}

function readInlineCode(text: string, start: number, sourceEnd = text.length): Match | undefined {
  const delimiterLength = backtickRunLength(text, start)
  const contentStart = start + delimiterLength
  let candidate = contentStart
  while (candidate < sourceEnd && text[candidate] !== "\n" && text[candidate] !== "\r") {
    if (text[candidate] !== "`") { candidate++; continue }
    const closingLength = backtickRunLength(text, candidate)
    if (closingLength === delimiterLength || closingLength === delimiterLength * 2) {
      return candidate > contentStart ? {
        start, end: candidate + delimiterLength, content: text.slice(contentStart, candidate),
        contentStart, contentEnd: candidate, type: MessageEntity_Type.CODE,
      } : undefined
    }
    candidate += closingLength
  }
  return undefined
}

function findEscapes(text: string, matches: Match[]): void {
  for (let index = 0; index + 1 < text.length; index++) {
    if (text[index] !== "\\" || !isMarkdownEscapable(text[index + 1])) continue
    matches.push({
      start: index,
      end: index + 2,
      content: text[index + 1]!,
      contentStart: index + 1,
      contentEnd: index + 2,
    })
    index += 1
  }
}

function normalizeRepeatedClosingFence(line: string, fence: MarkdownFence): string | undefined {
  const match = /^( {0,3})(`+|~+) \((×(?:[2-9]|[1-9]\d+))\)$/.exec(line)
  const run = match?.[2]
  if (!run || run[0] !== fence.character || run.length < fence.length) return undefined
  return `${match[1]}${run}\n(${match[3]})`
}

function backtickRunLength(text: string, start: number): number {
  let end = start
  while (text[end] === "`") end += 1
  return end - start
}

function readLink(text: string, start: number, depth: number, references: MarkdownReference[] = [], inlineCodes: MarkdownInlineCode[] = [], emphasis: MarkdownEmphasis[] = [], inlineRanges?: EntityRange[], characterReferences: MarkdownCharacterReference[] = []): Match | undefined {
  const textEnd = linkLabelEnd(text, start)
  if (textEnd === undefined || text[textEnd + 1] !== "(" || textEnd === start + 1) return undefined
  const destination = readInlineLinkDestination(text, textEnd + 2, start, inlineCodes)
  if (!destination || destination.end > inlineRangeEnd(inlineRanges, start, text.length)) return undefined
  const label = parseNestedContent(text.slice(start + 1, textEnd), depth, {
    references: relativeReferences(references, start + 1, textEnd),
    inlineCodes: relativeInlineCodes(inlineCodes, start + 1, textEnd),
    emphasis: relativeEmphasis(emphasis, start + 1, textEnd),
    inlineRanges: relativeInlineRanges(inlineRanges, start + 1, textEnd),
    characterReferences: relativeCharacterReferences(characterReferences, start + 1, textEnd),
    allowedTypes: new Set([
      MessageEntity_Type.BOLD, MessageEntity_Type.ITALIC, MessageEntity_Type.UNDERLINE,
      MessageEntity_Type.STRIKETHROUGH, MessageEntity_Type.HIGHLIGHT, MessageEntity_Type.MATH,
      MessageEntity_Type.CODE, MessageEntity_Type.PRE,
    ]),
  })
  return {
    start, end: destination.end, content: label.text, contentStart: start + 1, contentEnd: textEnd,
    type: destination.url ? MessageEntity_Type.TEXT_URL : undefined, url: destination.url,
    opaque: true,
    nestedEntities: label.entities, nestedSourceToOutput: label.sourceToOutput,
    mathRanges: shiftedMathRanges(label, start + 1),
  }
}

function referenceMatch(text: string, reference: MarkdownReference, depth: number, references: MarkdownReference[], inlineCodes: MarkdownInlineCode[], emphasis: MarkdownEmphasis[], inlineRanges?: EntityRange[], characterReferences: MarkdownCharacterReference[] = []): Match {
  const label = parseNestedContent(text.slice(reference.labelStart, reference.labelEnd), depth, {
    references: relativeReferences(references, reference.labelStart, reference.labelEnd),
    inlineCodes: relativeInlineCodes(inlineCodes, reference.labelStart, reference.labelEnd),
    emphasis: relativeEmphasis(emphasis, reference.labelStart, reference.labelEnd),
    inlineRanges: relativeInlineRanges(inlineRanges, reference.labelStart, reference.labelEnd),
    characterReferences: relativeCharacterReferences(characterReferences, reference.labelStart, reference.labelEnd),
    allowedTypes: new Set([MessageEntity_Type.BOLD, MessageEntity_Type.ITALIC, MessageEntity_Type.UNDERLINE,
      MessageEntity_Type.STRIKETHROUGH, MessageEntity_Type.HIGHLIGHT, MessageEntity_Type.MATH,
      MessageEntity_Type.CODE, MessageEntity_Type.PRE]),
  })
  return { start: reference.start + (reference.image ? 1 : 0), end: reference.end,
    contentStart: reference.labelStart, contentEnd: reference.labelEnd, content: label.text,
    type: reference.url ? MessageEntity_Type.TEXT_URL : undefined, url: reference.url, opaque: true,
    nestedEntities: label.entities, nestedSourceToOutput: label.sourceToOutput,
    mathRanges: shiftedMathRanges(label, reference.labelStart) }
}

export function relativeReferences(references: MarkdownReference[], start: number, end: number): MarkdownReference[] {
  return sourceRangesWithin(references, start, end).map((reference) => ({ ...reference,
    start: reference.start - start, end: reference.end - start,
    labelStart: reference.labelStart - start, labelEnd: reference.labelEnd - start }))
}

function findEmails(text: string, matches: Match[]): void {
  const regex = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi
  let match: RegExpExecArray | null

  while ((match = regex.exec(text)) !== null) {
    const email = match[0] ?? ""

    if (email.length > 0) {
      matches.push({
        start: match.index,
        end: match.index + email.length,
        content: email,
        contentStart: match.index,
        contentEnd: match.index + email.length,
        type: MessageEntity_Type.EMAIL,
      })
    }
  }
}

function findEmphasis(text: string, depth: number, references: MarkdownReference[], inlineCodes: MarkdownInlineCode[], emphasis: MarkdownEmphasis[], inlineRanges?: EntityRange[], characterReferences: MarkdownCharacterReference[] = []): Match[] {
  const matches: Match[] = []
  let end = -1
  for (const span of emphasis) {
    if (span.start < end) continue // Children are handled by the nested projection.
    const parsed = parseNestedContent(text.slice(span.contentStart, span.contentEnd), depth, {
      references: relativeReferences(references, span.contentStart, span.contentEnd),
      inlineCodes: relativeInlineCodes(inlineCodes, span.contentStart, span.contentEnd),
      emphasis: relativeEmphasis(emphasis, span.contentStart, span.contentEnd),
      inlineRanges: relativeInlineRanges(inlineRanges, span.contentStart, span.contentEnd),
      characterReferences: relativeCharacterReferences(characterReferences, span.contentStart, span.contentEnd),
    })
    matches.push({ ...span, content: parsed.text,
      type: span.kind === "strong" ? MessageEntity_Type.BOLD : MessageEntity_Type.ITALIC,
      nestedEntities: parsed.entities, nestedSourceToOutput: parsed.sourceToOutput,
      mathRanges: shiftedMathRanges(parsed, span.contentStart) })
    end = span.end
  }
  return matches
}

function findCompatibilityEmphasis(text: string, matches: Match[], depth: number, syntax: string, references: MarkdownReference[], inlineCodes: MarkdownInlineCode[], emphasis: MarkdownEmphasis[], inlineRanges?: EntityRange[], characterReferences: MarkdownCharacterReference[] = []): void {
  for (let cursor = 0; cursor < syntax.length; ) {
    const span = readPaddedEmphasis(syntax, cursor, inlineRangeEnd(inlineRanges, cursor, syntax.length), references)
    if (!span) { cursor++; continue }
    const content = parseNestedContent(text.slice(span.contentStart, span.contentEnd), depth, {
      references: relativeReferences(references, span.contentStart, span.contentEnd),
      inlineCodes: relativeInlineCodes(inlineCodes, span.contentStart, span.contentEnd),
      emphasis: relativeEmphasis(emphasis, span.contentStart, span.contentEnd),
      inlineRanges: relativeInlineRanges(inlineRanges, span.contentStart, span.contentEnd),
      characterReferences: relativeCharacterReferences(characterReferences, span.contentStart, span.contentEnd),
    })
    matches.push({ ...span, content: content.text, nestedEntities: content.entities,
      nestedSourceToOutput: content.sourceToOutput, mathRanges: shiftedMathRanges(content, span.contentStart) })
    cursor = span.end
  }
}

function findAdditionalStyles(text: string, matches: Match[], depth: number, references: MarkdownReference[] = [], inlineCodes: MarkdownInlineCode[] = [], emphasis: MarkdownEmphasis[] = [], inlineRanges?: EntityRange[], characterReferences: MarkdownCharacterReference[] = []): void {
  for (const style of additionalInlineStyles) {
    for (let cursor = 0; cursor < text.length; ) {
      const start = text.indexOf(style.open, cursor)
      if (start < 0) break
      const span = readInlineStyle(text, start, style, inlineRangeEnd(inlineRanges, start, text.length), { links: references })
      cursor = span?.end ?? start + style.open.length
      if (!span) continue
      const parsedContent = parseNestedContent(text.slice(span.contentStart, span.contentEnd), depth, {
        references: relativeReferences(references, span.contentStart, span.contentEnd),
        inlineCodes: relativeInlineCodes(inlineCodes, span.contentStart, span.contentEnd),
        emphasis: relativeEmphasis(emphasis, span.contentStart, span.contentEnd),
        inlineRanges: relativeInlineRanges(inlineRanges, span.contentStart, span.contentEnd),
        characterReferences: relativeCharacterReferences(characterReferences, span.contentStart, span.contentEnd),
      })
      matches.push({
        start,
        end: span.end,
        content: parsedContent.text,
        contentStart: span.contentStart,
        contentEnd: span.contentEnd,
        type: style.type,
        nestedEntities: parsedContent.entities,
        nestedSourceToOutput: parsedContent.sourceToOutput,
        mathRanges: shiftedMathRanges(parsedContent, span.contentStart),
      })
    }
  }
}
