import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { isMarkdownEscapable } from "./escape"
import { additionalInlineStyles, literalHTMLTokenEnd, maxInlineStyleDepth, readInlineStyle, readPaddedEmphasis } from "./inlineStyles"
import { isBlockMathSpan, mathLimits, readMathCandidate } from "./math"
import { urlEntities } from "./url"
import { linkLabelEnd, readInlineLinkDestination } from "./linkSyntax"
import { readFencedCode } from "./fences"
import { detectLiteralEntities } from "./literalDetectors"
import { sortEntities } from "./offsets"
import { textUrlEntity } from "./textUrl"
import type { EntityRange, MarkdownText } from "./types"
import { parseMarkdownDocument, relativeReferences } from "../../message/parseMarkdown"
import { hasVisibleMarkdownContent, relativeInlineCodes, relativeEmphasis, relativeInlineRanges, relativeCharacterReferences, type MarkdownCharacterReference, type MarkdownEmphasis, type MarkdownInlineCode, type MarkdownReference } from "../../message/markdownDocument"
import { removeSourceRanges } from "../../message/markdownSourceMap"

type ParsedMarkdownText = MarkdownText & { opaqueRanges: EntityRange[] }

type CodeParseResult = {
  type: MessageEntity_Type.CODE | MessageEntity_Type.PRE
  content: string
  language?: string
  end: number
}

type LinkParseResult = {
  label: string
  labelStart: number
  url: string
  end: number
}

const allowedLinkLabelEntityTypes = new Set<MessageEntity_Type>([
  MessageEntity_Type.BOLD,
  MessageEntity_Type.ITALIC,
  MessageEntity_Type.UNDERLINE,
  MessageEntity_Type.STRIKETHROUGH,
  MessageEntity_Type.HIGHLIGHT,
  MessageEntity_Type.MATH,
  MessageEntity_Type.CODE,
  MessageEntity_Type.PRE,
])

export const fromMd = (markdown: string): MarkdownText => {
  const { text, entities } = parseFromMd(markdown, 0)
  return { text, entities }
}

const parseFromMd = (markdown: string, depth: number, references: MarkdownReference[] = [], inlineCodes: MarkdownInlineCode[] = [], emphasis: MarkdownEmphasis[] = [], inlineRanges?: EntityRange[], characterReferences: MarkdownCharacterReference[] = []): ParsedMarkdownText => {
  if (depth >= maxInlineStyleDepth) return { text: markdown, entities: { entities: [] }, opaqueRanges: [{ start: 0, end: markdown.length }] }
  let text = ""
  const entities: MessageEntity[] = []
  const opaqueRanges: EntityRange[] = []
  const originalMarkdown = markdown
  const document = depth === 0 ? parseMarkdownDocument(markdown) : { codeBlocks: [], inlineCodes, emphasis, inlineRanges, characterReferences, definitions: [], references, prefixes: [], paragraphRanges: [] }
  if (!document) return { text: markdown, entities: { entities: [] }, opaqueRanges: [{ start: 0, end: markdown.length }] }
  let codeBlocks = document.codeBlocks, definitions = document.definitions
  references = document.references
  inlineCodes = document.inlineCodes
  emphasis = document.emphasis
  inlineRanges = document.inlineRanges
  characterReferences = document.characterReferences
  if (document.prefixes.length) {
    const projected = removeSourceRanges(markdown, document.prefixes)
    const boundary = (offset: number) => projected.sourceToOutput[offset]!
    markdown = projected.text
    // The original AST stays in source coordinates. Only the local scanner's
    // metadata moves; parsing the stripped source again would change nesting.
    codeBlocks = codeBlocks.map((block) => ({ ...block, start: boundary(block.start), end: boundary(block.end) }))
    inlineCodes = inlineCodes.map((code) => ({ ...code, start: boundary(code.start), end: boundary(code.end) }))
    characterReferences = characterReferences.map((span) => ({ ...span, start: boundary(span.start), end: boundary(span.end) }))
    emphasis = emphasis.map((span) => ({ ...span, start: boundary(span.start), end: boundary(span.end),
      contentStart: boundary(span.contentStart), contentEnd: boundary(span.contentEnd) }))
    inlineRanges = inlineRanges?.map((range) => ({ start: boundary(range.start), end: boundary(range.end) }))
    definitions = definitions.map((range) => ({ start: boundary(range.start), end: boundary(range.end) }))
    references = references.map((reference) => ({ ...reference, start: boundary(reference.start), end: boundary(reference.end),
      labelStart: boundary(reference.labelStart), labelEnd: boundary(reference.labelEnd) }))
  }
  const literalURLs = markdown.includes("$") ? urlEntities(markdown).map((url) => ({
    start: Number(url.offset), end: Number(url.offset + url.length),
  })) : []
  let urlIndex = 0
  let characterReferenceIndex = 0
  let codeIndex = 0
  let inlineCodeIndex = 0
  let definitionIndex = 0, referenceIndex = 0, emphasisIndex = 0, inlineRangeIndex = 0

  for (let i = 0; i < markdown.length; ) {
    while (inlineRanges?.[inlineRangeIndex] && inlineRanges[inlineRangeIndex]!.end <= i) inlineRangeIndex++
    const inlineRange = inlineRanges?.[inlineRangeIndex]
    const sourceEnd = !inlineRanges ? markdown.length : inlineRange && inlineRange.start <= i ? inlineRange.end : i
    while (definitions[definitionIndex] && definitions[definitionIndex]!.end <= i) definitionIndex++
    const definition = definitions[definitionIndex]
    if (definition?.start === i) {
      i = definition.end
      continue
    }
    while (references[referenceIndex] && references[referenceIndex]!.end <= i) referenceIndex++
    while (inlineCodes[inlineCodeIndex] && inlineCodes[inlineCodeIndex]!.end <= i) inlineCodeIndex++
    while (codeBlocks[codeIndex] && codeBlocks[codeIndex]!.end <= i) codeIndex++
    const block = codeBlocks[codeIndex]
    if (block?.start === i) {
      if (block.content.length > 0) entities.push(codeEntity({ ...block, type: MessageEntity_Type.PRE }, text.length))
      text += block.content
      i = block.end
      continue
    }
    // Nested label/style projection must not reclassify verified inline code
    // as a root fence. Embedded PRE retains its transport policy below.
    if ((i === 0 || markdown[i - 1] === "\n") && inlineCodes[inlineCodeIndex]?.start !== i) {
      const fence = readFencedCode(markdown, i)
      if (fence) {
        // Keep translation's existing whitespace-preserving code body policy.
        text += markdown.slice(i, fence.start)
        const content = markdown.slice(fence.contentStart, fence.contentEnd)
        if (content.length > 0) entities.push(codeEntity({ type: MessageEntity_Type.PRE, content,
          language: fence.language, end: fence.end }, text.length))
        text += content
        i = fence.end
        continue
      }
    }
    while (emphasis[emphasisIndex] && emphasis[emphasisIndex]!.end <= i) emphasisIndex++
    const emphasisSpan = emphasis[emphasisIndex]
    if (emphasisSpan?.start === i) {
      const offset = text.length
      const content = parseFromMd(markdown.slice(emphasisSpan.contentStart, emphasisSpan.contentEnd), depth + 1,
        relativeReferences(references, emphasisSpan.contentStart, emphasisSpan.contentEnd),
        relativeInlineCodes(inlineCodes, emphasisSpan.contentStart, emphasisSpan.contentEnd),
        relativeEmphasis(emphasis, emphasisSpan.contentStart, emphasisSpan.contentEnd),
        relativeInlineRanges(inlineRanges, emphasisSpan.contentStart, emphasisSpan.contentEnd),
        relativeCharacterReferences(characterReferences, emphasisSpan.contentStart, emphasisSpan.contentEnd))
      opaqueRanges.push(...content.opaqueRanges.map((range) => ({ start: offset + range.start, end: offset + range.end })))
      text += content.text
      if (content.text.length) entities.push({
        type: emphasisSpan.kind === "strong" ? MessageEntity_Type.BOLD : MessageEntity_Type.ITALIC,
        offset: BigInt(offset), length: BigInt(content.text.length), entity: { oneofKind: undefined },
      })
      entities.push(...content.entities.entities.map((entity) => ({ ...entity, offset: entity.offset + BigInt(offset) })))
      i = emphasisSpan.end
      continue
    }
    while (literalURLs[urlIndex] && literalURLs[urlIndex]!.end <= i) urlIndex++
    const math = markdown[i] === "$"
      && !(literalURLs[urlIndex] && literalURLs[urlIndex]!.start <= i)
      && readMathCandidate(markdown, i)
    if (math) {
      const content = markdown.slice(math.contentStart, math.contentEnd)
      if (content.length <= (math.display ? mathLimits.displaySource : mathLimits.inlineSource)) {
        entities.push({
          type: MessageEntity_Type.MATH, offset: BigInt(text.length), length: BigInt(content.length),
          entity: depth === 0 && isBlockMathSpan(markdown, i, math)
            ? { oneofKind: "math", math: { display: true } }
            : { oneofKind: undefined },
        })
        text += content
      } else {
        opaqueRanges.push({ start: text.length, end: text.length + math.end - i })
        text += markdown.slice(i, math.end)
      }
      i = math.end
      continue
    }

    if (markdown[i] === "\\" && isMarkdownEscapable(markdown[i + 1])) {
      text += markdown[i + 1]
      i += 2
      continue
    }
    const htmlEnd = literalHTMLTokenEnd(markdown, i)
    if (htmlEnd !== undefined) {
      text += markdown.slice(i, htmlEnd)
      i = htmlEnd
      continue
    }

    while (characterReferences[characterReferenceIndex] && characterReferences[characterReferenceIndex]!.end <= i) characterReferenceIndex++
    const characterReference = characterReferences[characterReferenceIndex]
    if (characterReference?.start === i) {
      text += characterReference.content
      i = characterReference.end
      continue
    }

    if (markdown[i] === "`") {
      const mapped = inlineCodes[inlineCodeIndex]?.start === i ? inlineCodes[inlineCodeIndex] : undefined
      const legacy = readCode(markdown, i)
      // Embedded PRE is an established transport convention. Preserve its
      // language/whitespace only when it also fits a real inline-code span.
      const parsed = legacy?.type === MessageEntity_Type.PRE
        ? (mapped?.end === legacy.end ? legacy : null)
        : mapped ? { ...mapped, type: MessageEntity_Type.CODE as const } : legacy
      if (parsed && parsed.end <= sourceEnd) {
        const offset = text.length
        text += parsed.content
        if (parsed.content.length > 0) {
          entities.push(codeEntity(parsed, offset))
        }
        i = parsed.end
        continue
      }
    }

    if (markdown[i] === "[") {
      const reference = references[referenceIndex]
      const link = reference && reference.start + (reference.image ? 1 : 0) === i
        ? { label: markdown.slice(reference.labelStart, reference.labelEnd), labelStart: reference.labelStart,
          url: reference.url, end: reference.end }
        : readMarkdownLink(markdown, i, inlineCodes)
      if (link && link.end <= sourceEnd) {
        const offset = text.length
        const label = parseFromMd(link.label, depth + 1,
          relativeReferences(references, link.labelStart, link.labelStart + link.label.length),
          relativeInlineCodes(inlineCodes, link.labelStart, link.labelStart + link.label.length),
          relativeEmphasis(emphasis, link.labelStart, link.labelStart + link.label.length),
          relativeInlineRanges(inlineRanges, link.labelStart, link.labelStart + link.label.length),
          relativeCharacterReferences(characterReferences, link.labelStart, link.labelStart + link.label.length))
        opaqueRanges.push(...label.opaqueRanges.map((range) => ({ start: offset + range.start, end: offset + range.end })))
        text += label.text
        for (const entity of label.entities.entities) {
          if (!allowedLinkLabelEntityTypes.has(entity.type)) {
            continue
          }
          entities.push({
            ...entity,
            offset: entity.offset + BigInt(offset),
          })
        }

        const linkEntity = normalizeParsedLinkEntity(
          text,
          textUrlEntity({ url: link.url, offset, length: label.text.length }),
        )
        if (linkEntity) {
          entities.push(linkEntity)
        }

        i = link.end
        continue
      }

      text += markdown[i]
      i += 1
      continue
    }

    const style = additionalInlineStyles.find((candidate) => markdown.startsWith(candidate.open, i))
    const padded = !style && readPaddedEmphasis(markdown, i, sourceEnd, references)
    const span = style ? readInlineStyle(markdown, i, style, sourceEnd, { links: references }) : padded || undefined
    const styleType = style?.type ?? (padded ? padded.type : undefined)
    if (styleType !== undefined && span && !(block && i < block.start && block.start < span.end)) {
      const offset = text.length
      const content = parseFromMd(markdown.slice(span.contentStart, span.contentEnd), depth + 1,
        relativeReferences(references, span.contentStart, span.contentEnd),
        relativeInlineCodes(inlineCodes, span.contentStart, span.contentEnd),
        relativeEmphasis(emphasis, span.contentStart, span.contentEnd),
        relativeInlineRanges(inlineRanges, span.contentStart, span.contentEnd),
        relativeCharacterReferences(characterReferences, span.contentStart, span.contentEnd))
      opaqueRanges.push(...content.opaqueRanges.map((range) => ({ start: offset + range.start, end: offset + range.end })))
      text += content.text
      entities.push({ type: styleType, offset: BigInt(offset), length: BigInt(content.text.length), entity: { oneofKind: undefined } })
      entities.push(...content.entities.entities.map((entity) => ({ ...entity, offset: entity.offset + BigInt(offset) })))
      i = span.end
      continue
    }

    text += markdown[i]
    i += 1
  }

  if (document.definitions.length && (text.trim().length === 0 || (!opaqueRanges.length
    && !entities.some((entity) => entity.type === MessageEntity_Type.MATH) && !hasVisibleMarkdownContent(document)))) {
    return { text: originalMarkdown, entities: { entities: [] }, opaqueRanges: [{ start: 0, end: originalMarkdown.length }] }
  }

  return {
    text,
    entities: {
      entities: detectLiteralEntities(text, sortEntities(entities), opaqueRanges),
    },
    opaqueRanges,
  }
}

const normalizeParsedLinkEntity = (text: string, entity: MessageEntity | null): MessageEntity | null => {
  if (!entity || entity.type !== MessageEntity_Type.MENTION) {
    return entity
  }

  const start = Number(entity.offset)
  const length = Number(entity.length)
  let nextStart = start
  let nextEnd = start + length

  while (nextStart < nextEnd && /\s/u.test(text[nextStart] ?? "")) {
    nextStart += 1
  }

  while (nextEnd > nextStart && /\s/u.test(text[nextEnd - 1] ?? "")) {
    nextEnd -= 1
  }

  if (nextStart === nextEnd) {
    return null
  }

  if (nextStart === start && nextEnd === start + length) {
    return entity
  }

  return {
    ...entity,
    offset: BigInt(nextStart),
    length: BigInt(nextEnd - nextStart),
  }
}

const codeEntity = (parsed: CodeParseResult, offset: number): MessageEntity => {
  const base = {
    type: parsed.type,
    offset: BigInt(offset),
    length: BigInt(parsed.content.length),
  }

  if (parsed.type === MessageEntity_Type.PRE) {
    return {
      ...base,
      entity: {
        oneofKind: "pre",
        pre: { language: parsed.language ?? "" },
      },
    }
  }

  return {
    ...base,
    entity: { oneofKind: undefined },
  }
}

const readCode = (markdown: string, start: number): CodeParseResult | null => {
  const marker = readBackticks(markdown, start)
  if (!marker) {
    return null
  }

  if (marker.length >= 3) {
    const pre = readPre(markdown, start, marker)
    if (pre) {
      return pre
    }
  }

  const contentStart = start + marker.length
  const close = markdown.indexOf(marker, contentStart)
  if (close === -1 || /[\r\n]/.test(markdown.slice(contentStart, close))) {
    return null
  }

  return {
    type: MessageEntity_Type.CODE,
    content: markdown.slice(contentStart, close),
    end: close + marker.length,
  }
}

const readPre = (markdown: string, start: number, marker: string): CodeParseResult | null => {
  const headerStart = start + marker.length
  const newline = markdown.indexOf("\n", headerStart)
  if (newline === -1) {
    return null
  }

  const language = markdown.slice(headerStart, newline).trim()
  if (language.includes("`")) {
    return null
  }

  const contentStart = newline + 1
  const close = markdown.indexOf(marker, contentStart)
  if (close === -1) {
    return null
  }

  return {
    type: MessageEntity_Type.PRE,
    content: markdown.slice(contentStart, close),
    language,
    end: close + marker.length,
  }
}

const readBackticks = (text: string, start: number): string | null => {
  let end = start
  while (text[end] === "`") {
    end += 1
  }

  if (end === start) {
    return null
  }

  return text.slice(start, end)
}

const readMarkdownLink = (markdown: string, start: number, inlineCodes: MarkdownInlineCode[]): LinkParseResult | null => {
  return readDoubleBracketLink(markdown, start, inlineCodes) ?? readBracketLink(markdown, start, inlineCodes)
}

const readDoubleBracketLink = (markdown: string, start: number, inlineCodes: MarkdownInlineCode[]): LinkParseResult | null => {
  if (!markdown.startsWith("[[", start)) return null
  const end = linkLabelEnd(markdown, start)
  if (end === undefined || markdown[end - 1] !== "]" || markdown[end + 1] !== "(") return null
  const parsedUrl = readInlineLinkDestination(markdown, end + 2, start, inlineCodes)
  // Keep the historical visible [[thread label]] form.
  return parsedUrl ? { label: markdown.slice(start, end + 1), labelStart: start, url: parsedUrl.url, end: parsedUrl.end } : null
}

const readBracketLink = (markdown: string, start: number, inlineCodes: MarkdownInlineCode[]): LinkParseResult | null => {
  const end = linkLabelEnd(markdown, start)
  if (end === undefined || markdown[end + 1] !== "(") return null
  const parsedUrl = readInlineLinkDestination(markdown, end + 2, start, inlineCodes)
  return parsedUrl ? { label: markdown.slice(start + 1, end), labelStart: start + 1, url: parsedUrl.url, end: parsedUrl.end } : null
}
