import { MessageEntity_Type, type MessageEntities, type MessageEntity } from "@inline-chat/protocol/core"
import { boldMd } from "./bold"
import { cleanPreLanguage, codeDelimiter, preFence } from "./code"
import { escapeLinkUrl, escapeMdText } from "./escape"
import { italicMd } from "./italic"
import { mentionMdUrl } from "./mention"
import { groupMentionMdUrl } from "./groupMention"
import { contains, toRange } from "./offsets"
import { prepareMarkdownInlineSyntax } from "../../message/markdownDocument"
import { policyFor } from "./registry"
import { isBlockMathSpan, mathMarkdown } from "./math"
import { inlineStyleTags } from "./inlineStyles"
import { textUrlEntity } from "./textUrl"
import { threadMdUrl } from "./thread"
import { threadTitleMdUrl } from "./threadTitle"
import type { MarkdownEntity } from "./types"
import { urlEntities } from "./url"

export const toMd = (
  text: string,
  entities: MessageEntities | null | undefined,
  escapeText: (text: string, atLineStart?: boolean) => string = escapeMdText,
): string => {
  if (!entities?.entities.length) {
    return escapeText(text)
  }

  const markdownEntities = normalizeMarkdownEntities(text, entities.entities)
  if (markdownEntities.length === 0) {
    return escapeText(text)
  }

  const starts = new Map<number, MarkdownEntity[]>()
  const ends = new Map<number, MarkdownEntity[]>()
  const positions = new Set<number>([0, text.length])

  for (const entity of markdownEntities) {
    positions.add(entity.start)
    positions.add(entity.end)

    const startItems = starts.get(entity.start) ?? []
    startItems.push(entity)
    starts.set(entity.start, startItems)

    const endItems = ends.get(entity.end) ?? []
    endItems.push(entity)
    ends.set(entity.end, endItems)
  }

  const sortedPositions = [...positions].sort((a, b) => a - b)
  let result = ""
  let rawDepth = 0
  let linkDepth = 0

  for (let index = 0; index < sortedPositions.length; index++) {
    const position = sortedPositions[index]!

    const closing = (ends.get(position) ?? []).sort(closeSort)
    for (const item of closing) {
      result += item.close
      if (item.raw) {
        rawDepth -= 1
      }
      if (item.open === "[") linkDepth -= 1
    }

    const opening = (starts.get(position) ?? []).sort(openSort)
    for (const item of opening) {
      result += item.open
      if (item.raw) {
        rawDepth += 1
      }
      if (item.open === "[") linkDepth += 1
    }

    const next = sortedPositions[index + 1]
    if (next === undefined || next === position) {
      continue
    }

    const slice = text.slice(position, next)
    if (rawDepth > 0) result += slice
    else {
      const escaped = escapeText(slice, position === 0 || text[position - 1] === "\n" || text[position - 1] === "\r")
      // Physical line breaks can end a Markdown label's paragraph. Standard
      // references preserve native label text, including blank lines, without
      // exposing block syntax. Verbatim code/math keeps its own source bytes.
      result += linkDepth > 0 ? escaped.replace(/\r/g, "&#13;").replace(/\n/g, "&#10;") : escaped
    }
  }

  return result
}

const normalizeMarkdownEntities = (text: string, entities: MessageEntity[]): MarkdownEntity[] => {
  const literalURLs = entities.some((entity) => entity.type === MessageEntity_Type.MATH) ? urlEntities(text) : []
  const candidates = entities
    .filter((entity) => entity.type !== MessageEntity_Type.MATH || !literalURLs.some((url) =>
      url.offset < entity.offset && entity.offset < url.offset + url.length))
    .map((entity) => toMarkdownEntity(text, entity))
    .filter((entity): entity is MarkdownEntity => entity !== null)
    // Mention whitespace trimming can move a source start. Conflict selection
    // must use the actual emitted ranges, not the untrimmed input ordering.
    .sort((a, b) => a.start - b.start || b.end - a.end || a.entity.type - b.entity.type)

  const accepted: MarkdownEntity[] = []
  const formattingEnds = new Map<MessageEntity_Type, number>()
  const mathCandidates = candidates.filter((candidate) => candidate.entity.type === MessageEntity_Type.MATH)
  const mathStarts = new Set(mathCandidates.map((candidate) => candidate.start))
  const mathEnds = new Set(mathCandidates.map((candidate) => candidate.end))
  // Adjacent dollar delimiters are ambiguous. Preserve literal TeX instead.
  const eligible = candidates.filter((candidate) => candidate.entity.type !== MessageEntity_Type.MATH
    || (!mathStarts.has(candidate.end) && !mathEnds.has(candidate.start)))
  // Verbatim spans take precedence over conflicting semantic targets. Nested
  // or crossing raw delimiters themselves are not representable: retain the
  // first source range (longest first at a shared start), without mutating it.
  const raw: MarkdownEntity[] = []
  const codeValidity = new Map<string, boolean>()
  // Nonoverlapping code costs at most one source traversal. Malformed native
  // overlaps may need retries, but cannot amplify canonical AST parsing without
  // bound. Budget exhaustion keeps source text and omits only that CODE style.
  let codeValidationBudget = Math.max(4_096, text.length * 4)
  for (const candidate of eligible) {
    if (!candidate.raw || candidate.start < (raw.at(-1)?.end ?? -1)) continue
    if (candidate.entity.type === MessageEntity_Type.CODE) {
      const key = `${candidate.start}:${candidate.end}`
      let valid = codeValidity.get(key)
      if (valid === undefined) {
        const content = text.slice(candidate.start, candidate.end)
        const cost = /[\r\n]/.test(content) ? content.length : 0
        valid = cost <= codeValidationBudget && representableInlineCode(content)
        codeValidationBudget = Math.max(0, codeValidationBudget - cost)
        codeValidity.set(key, valid)
      }
      if (!valid) continue
      candidate.open = candidate.close = codeDelimiter(text.slice(candidate.start, candidate.end))
    }
    raw.push(candidate)
  }
  const selectedRaw = new Set(raw)
  const rawBlocks = raw.filter((item) => item.entity.type === MessageEntity_Type.PRE || item.open === "$$")
  const rawEndingAfter = (offset: number): MarkdownEntity | undefined => {
    let low = 0, high = raw.length
    while (low < high) {
      const middle = (low + high) >>> 1
      if (raw[middle]!.end <= offset) low = middle + 1
      else high = middle
    }
    return raw[low]
  }
  let semanticEnd = -1, blockIndex = 0
  for (const candidate of eligible) {
    // Formatting is idempotent. Repeating a delimiter for the same style can
    // turn italic into bold, strike into a fence, or toggle an inner span off.
    // Source order puts containing ranges first; omit their redundant children
    // before overlap checks so they cannot also displace a valid semantic link.
    if (isFormatting(candidate)) {
      // Candidates are ordered by start, then longest first. The greatest
      // previous end for this style is sufficient to detect containment.
      if ((formattingEnds.get(candidate.entity.type) ?? -1) >= candidate.end) continue
      formattingEnds.set(candidate.entity.type, candidate.end)
    }
    if (candidate.raw) {
      if (!selectedRaw.has(candidate)) continue
    } else if (!isFormatting(candidate)) {
      // Markdown cannot nest links. Keep one target in source order; a longer
      // outer range precedes an inner one. Siblings still remain independent.
      if (candidate.start < semanticEnd) continue
      while (rawBlocks[blockIndex] && rawBlocks[blockIndex]!.end <= candidate.start) blockIndex++
      if (rawBlocks[blockIndex] && rawBlocks[blockIndex]!.start < candidate.end) continue
      // Complete inline code/math may be a link label, but neither endpoint
      // may cut its verbatim body. Binary lookup also bounds rejected spans.
      const startRaw = rawEndingAfter(candidate.start), endRaw = rawEndingAfter(candidate.end)
      if ((startRaw && startRaw.start < candidate.start) || (endRaw && endRaw.start < candidate.end)) continue
      semanticEnd = candidate.end
    }

    accepted.push(candidate)
  }

  return protectFormattingBoundaries(text, splitMultilineFormatting(text, splitCrossingFormatting(text, accepted)))
}

const isFormatting = (item: MarkdownEntity): boolean => item.entity.type === MessageEntity_Type.BOLD
  || item.entity.type === MessageEntity_Type.ITALIC || item.entity.type === MessageEntity_Type.UNDERLINE
  || item.entity.type === MessageEntity_Type.STRIKETHROUGH || item.entity.type === MessageEntity_Type.HIGHLIGHT

const formattingRange = (item: MarkdownEntity, start: number, end: number): MarkdownEntity => ({
  ...item, start, end, entity: { ...item.entity, offset: BigInt(start), length: BigInt(end - start) },
})

/** Markdown wrappers must nest, but native formatting can cross another style
 * or a semantic link. Split only formatting; keep semantic/raw spans whole.
 * There are at most five active styles per segment, independent of how many
 * overlapping copies the source contains. Existing nested output is retained. */
const splitCrossingFormatting = (text: string, entities: MarkdownEntity[]): MarkdownEntity[] => {
  const anchors = entities.filter((item) => !isFormatting(item)), raw = anchors.filter((item) => item.raw)
  const embeddedDisplay = new Set(raw.filter((item) => {
    if (item.open !== "$$") return false
    // Indentation is not prose. A formula is mixed into a paragraph only if
    // the same physical line contains visible source outside its boundaries.
    for (let index = item.start - 1; index >= 0 && text[index] !== "\r" && text[index] !== "\n"; index--) {
      if (/\S/u.test(text[index]!)) return true
    }
    for (let index = item.end; index < text.length && text[index] !== "\r" && text[index] !== "\n"; index++) {
      if (/\S/u.test(text[index]!)) return true
    }
    return false
  }))
  const firstRawEndingAfter = (offset: number): number => {
    let low = 0, high = raw.length
    while (low < high) {
      const middle = (low + high) >>> 1
      if (raw[middle]!.end <= offset) low = middle + 1
      else high = middle
    }
    return low
  }
  const formatting = entities.filter(isFormatting).flatMap((item) => {
    let parts = [item]
    for (let index = firstRawEndingAfter(item.start); index < raw.length; index++) {
      const span = raw[index]!
      if (span.start >= item.end) break
      // An outer wrapper may cover complete inline code or a formula. Fenced
      // PRE and display TeX must remain at block boundaries; even a complete
      // wrapper breaks their opening/closing fences. Never insert syntax into
      // a verbatim body.
      if (span.entity.type !== MessageEntity_Type.PRE && contains(item, span)) {
        if (span.open !== "$$") continue
        if (embeddedDisplay.has(span)) {
          const tag = inlineStyleTags.find((style) => style.type === item.entity.type)!
          parts = parts.map((part) => ({ ...part, open: tag.open, close: tag.close }))
          continue
        }
      }
      parts = parts.flatMap((part) => {
        if (part.end <= span.start || part.start >= span.end) return [part]
        const kept: MarkdownEntity[] = []
        if (part.start < span.start) kept.push(formattingRange(part, part.start, span.start))
        if (part.end > span.end) kept.push(formattingRange(part, span.end, part.end))
        return kept
      })
    }
    return parts
  })
  const ranges = [...anchors, ...formatting]
  const sort = (items: MarkdownEntity[]) => items.sort((a, b) => a.start - b.start || b.end - a.end || priority(a) - priority(b))
  sort(ranges)
  const stack: MarkdownEntity[] = [], styleEnds = new Map<MessageEntity_Type, number>()
  let crossing = false
  for (const item of ranges) {
    while (stack.length && stack.at(-1)!.end <= item.start) stack.pop()
    const parent = stack.at(-1)
    if (parent && item.end > parent.end && (isFormatting(item) || isFormatting(parent))) { crossing = true; break }
    if (isFormatting(item)) {
      if ((styleEnds.get(item.entity.type) ?? -1) > item.start) { crossing = true; break }
      styleEnds.set(item.entity.type, item.end)
    }
    stack.push(item)
  }
  if (!crossing) return mergeAdjacentFormatting(ranges)

  const events = new Map<number, { item: MarkdownEntity; delta: number }[]>()
  for (const item of formatting) for (const [position, delta] of [[item.start, 1], [item.end, -1]] as const) {
    const entries = events.get(position) ?? []
    entries.push({ item, delta })
    events.set(position, entries)
  }
  const anchorPositions = new Set(anchors.flatMap((item) => [item.start, item.end]))
  const positions = [...new Set([...events.keys(), ...anchorPositions])].sort((a, b) => a - b)
  const active = new Map<MessageEntity_Type, { item: MarkdownEntity; count: number }>()
  const result = [...anchors]
  const open: { item: MarkdownEntity; start: number }[] = []
  for (const end of positions) {
    for (const { item, delta } of events.get(end) ?? []) {
      const count = (active.get(item.entity.type)?.count ?? 0) + delta
      if (count === 0) active.delete(item.entity.type)
      else active.set(item.entity.type, { item, count })
    }
    const next = [...active.values()].map(({ item }) => item).sort((a, b) => priority(a) - priority(b))
    // Keep the common outer wrappers open. Count-only changes need no work;
    // a changed inner style closes/reopens at most five formatting wrappers.
    // Semantic boundaries force a split so their own spans remain indivisible.
    let keep = 0
    if (!anchorPositions.has(end)) {
      while (keep < open.length && keep < next.length && open[keep]!.item.entity.type === next[keep]!.entity.type) keep++
    }
    while (open.length > keep) {
      const { item, start } = open.pop()!
      // Exact tags avoid ambiguous joined marker runs when a style resumes.
      const tag = inlineStyleTags.find((style) => style.type === item.entity.type)!
      result.push({ ...formattingRange(item, start, end), open: tag.open, close: tag.close })
    }
    for (let index = keep; index < next.length; index++) open.push({ item: next[index]!, start: end })
  }
  return sort(result)
}

/** Native ranges are not constrained by Markdown delimiter flanking. Retain
 * the familiar markers for ordinary words, and use exact formatting tags for
 * punctuation/whitespace boundaries. Inner wrappers can also make an outer
 * emphasis marker touch punctuation next to an unformatted word. */
const protectFormattingBoundaries = (text: string, entities: MarkdownEntity[]): MarkdownEntity[] => {
  const scalarBefore = (offset: number) => Array.from(text.slice(Math.max(0, offset - 2), offset)).at(-1) ?? ""
  const scalarAfter = (offset: number) => Array.from(text.slice(offset, offset + 2))[0] ?? ""
  const word = (scalar: string) => /^[\p{L}\p{M}\p{N}]$/u.test(scalar)
  const result = entities.map((item) => ({ ...item }))
  const starts = new Map<number, MarkdownEntity[]>(), ends = new Map<number, MarkdownEntity[]>()
  for (const item of result) {
    const opening = starts.get(item.start) ?? [], closing = ends.get(item.end) ?? []
    opening.push(item)
    closing.push(item)
    starts.set(item.start, opening)
    ends.set(item.end, closing)
  }
  // Inner decisions are settled before considering an enclosing emphasis.
  const formatting = result.filter(isFormatting).sort((a, b) => (a.end - a.start) - (b.end - b.start) || priority(b) - priority(a))
  for (const item of formatting) {
    const tag = inlineStyleTags.find((style) => style.type === item.entity.type)!
    if (item.open === tag.open) continue
    let useTag = !word(scalarAfter(item.start)) || !word(scalarBefore(item.end))
    if (item.open === "~~" || item.open === "==") {
      useTag ||= text[item.start - 1] === item.open[0] || text[item.end] === item.open[0]
    }
    if (!useTag && (item.entity.type === MessageEntity_Type.BOLD || item.entity.type === MessageEntity_Type.ITALIC)) {
      const child = (inner: MarkdownEntity) => inner !== item && contains(item, inner)
        && (inner.start !== item.start || inner.end !== item.end || priority(inner) > priority(item))
      useTag = (word(scalarBefore(item.start)) && (starts.get(item.start) ?? []).some((inner) => child(inner) && !inner.open.startsWith("*")))
        || (word(scalarAfter(item.end)) && (ends.get(item.end) ?? []).some((inner) => child(inner) && !inner.close.endsWith("*")))
    }
    if (useTag) { item.open = tag.open; item.close = tag.close }
  }
  return result
}

/** Avoid ambiguous adjacent delimiter runs in exported native formatting.
 * Joining siblings can create a new crossing with a semantic anchor or another
 * style, so each proposed union must remain laminar with the live range set. */
const mergeAdjacentFormatting = (entities: MarkdownEntity[]): MarkdownEntity[] => {
  if (!entities.some(isFormatting)) return entities
  const result: (MarkdownEntity | undefined)[] = [...entities]
  const starts = new Map<number, Set<MarkdownEntity>>()
  const ends = new Map<number, Set<MarkdownEntity>>()
  const insert = (item: MarkdownEntity) => {
    for (const [map, position] of [[starts, item.start], [ends, item.end]] as const) {
      const bucket = map.get(position) ?? new Set<MarkdownEntity>()
      bucket.add(item)
      map.set(position, bucket)
    }
  }
  const remove = (item: MarkdownEntity) => {
    starts.get(item.start)?.delete(item)
    ends.get(item.end)?.delete(item)
  }
  entities.forEach(insert)
  const previous = new Map<MessageEntity_Type, number>()
  for (let index = 0; index < result.length; index++) {
    const item = result[index]!
    if (!isFormatting(item)) continue
    const previousIndex = previous.get(item.entity.type)
    const before = previousIndex === undefined ? undefined : result[previousIndex]
    if (before?.end === item.start) {
      const merged = { ...before, end: item.end,
        entity: { ...before.entity, length: BigInt(item.end - before.start) } }
      // The input is laminar and same-style overlaps were removed. Only
      // intervals touching this join can newly cross the union. Each bucket
      // has at most five styles plus semantic/raw anchors; update it after
      // every merge so an earlier union can block a later style's union.
      const createsCrossing = [...(ends.get(item.start) ?? [])].some((other) => other.start < before.start)
        || [...(starts.get(item.start) ?? [])].some((other) => other.end > item.end)
      if (!createsCrossing) {
        remove(before)
        remove(item)
        insert(merged)
        result[previousIndex!] = merged
        result[index] = undefined
        continue
      }
    }
    previous.set(item.entity.type, index)
  }
  return result.filter((item): item is MarkdownEntity => item !== undefined)
}

/** Native ranges may cover multiple paragraphs. Markdown emphasis cannot, so
 * serialize those styles per line while keeping text and semantic entities
 * intact. Newlines within code, TeX, and link labels belong to that opaque
 * projection and must not be split by surrounding formatting. */
const splitMultilineFormatting = (text: string, entities: MarkdownEntity[]): MarkdownEntity[] => {
  if (!/[\r\n]/.test(text)) return entities
  if (!entities.some(isFormatting)) return entities
  const protectedRanges = entities.filter((item) => !isFormatting(item)).sort((a, b) => a.start - b.start)
  let protectedIndex = 0
  const breaks = [...text.matchAll(/\r\n|\r|\n/g)].map((match) => ({ start: match.index, end: match.index + match[0].length }))
    .filter((range) => {
      while (protectedRanges[protectedIndex] && protectedRanges[protectedIndex]!.end <= range.start) protectedIndex++
      const item = protectedRanges[protectedIndex]
      return !item || item.start >= range.end
    })
  if (!breaks.length) return entities
  return entities.flatMap((item) => {
    if (!isFormatting(item)) return [item]
    const parts: MarkdownEntity[] = []
    let cursor = item.start
    let split = false
    let low = 0, high = breaks.length
    while (low < high) {
      const middle = (low + high) >>> 1
      if (breaks[middle]!.end <= item.start) low = middle + 1
      else high = middle
    }
    for (let index = low; index < breaks.length; index++) {
      const range = breaks[index]!
      if (range.start >= item.end) break
      split = true
      if (range.start > cursor) parts.push({ ...item, start: cursor, end: range.start })
      cursor = Math.min(item.end, range.end)
    }
    if (!split) return [item]
    if (cursor < item.end) parts.push({ ...item, start: cursor })
    return parts
  })
}

const toMarkdownEntity = (text: string, entity: MessageEntity): MarkdownEntity | null => {
  if (policyFor(entity.type) !== "markdown") {
    return null
  }

  const range = toRange(text, entity)
  if (!range) {
    return null
  }

  switch (entity.type) {
    case MessageEntity_Type.BOLD:
      return { ...range, entity, open: boldMd.open, close: boldMd.close, raw: false }
    case MessageEntity_Type.ITALIC:
      return { ...range, entity, open: italicMd.open, close: italicMd.close, raw: false }
    case MessageEntity_Type.UNDERLINE:
      return { ...range, entity, open: "<u>", close: "</u>", raw: false }
    case MessageEntity_Type.STRIKETHROUGH:
      return { ...range, entity, open: "~~", close: "~~", raw: false }
    case MessageEntity_Type.HIGHLIGHT:
      return { ...range, entity, open: "==", close: "==", raw: false }
    case MessageEntity_Type.MATH: {
      const content = text.slice(range.start, range.end)
      const display = entity.entity.oneofKind === "math" && entity.entity.math.display
      // A following digit prevents an inline close (currency protection).
      const inline = !display && !/[0-9]/u.test(text[range.end] ?? "") && mathMarkdown(content)
      // Double dollars carry display intent when they own a line. Do not use
      // that syntax to serialize an unmarked line-owning range: readable
      // literal fallback is safer than silently changing its layout meaning.
      const doubleWouldBeDisplay = isBlockMathSpan(text, range.start, {
        contentStart: range.start,
        contentEnd: range.end,
        end: range.end,
        display: true,
      })
      const delimiter = inline ? "$"
        : (display || !doubleWouldBeDisplay) && mathMarkdown(content, true) ? "$$" : undefined
      return delimiter ? { ...range, entity, open: delimiter, close: delimiter, raw: true } : null
    }
    case MessageEntity_Type.CODE: {
      // Resolve the actual delimiter only for the selected raw interval.
      return { ...range, entity, open: "`", close: "`", raw: true }
    }
    case MessageEntity_Type.PRE: {
      const content = text.slice(range.start, range.end)
      const fence = preFence(content)
      const language = entity.entity.oneofKind === "pre" ? cleanPreLanguage(entity.entity.pre.language) : ""
      const open = `${fence}${language ? language : ""}\n`
      // A block-aligned PRE needs a closing fence on its own line. Embedded
      // PRE keeps the existing internal transport convention; it cannot be
      // converted to a block without inserting text around the native range.
      const blockAligned = (range.start === 0 || text[range.start - 1] === "\n" || text[range.start - 1] === "\r")
        && (range.end === text.length || text[range.end] === "\n" || text[range.end] === "\r")
      const close = blockAligned && !content.endsWith("\n") ? `\n${fence}` : fence
      return { ...range, entity, open, close, raw: true }
    }
    case MessageEntity_Type.TEXT_URL:
      if (entity.entity.oneofKind !== "textUrl") {
        return null
      }
      return linkEntity(range, entity, entity.entity.textUrl.url)
    case MessageEntity_Type.MENTION:
      if (entity.entity.oneofKind !== "mention") {
        return null
      }
      return linkEntity(
        trimRangeWhitespace(text, range),
        entity,
        mentionMdUrl(entity.entity.mention.userId, entity.entity.mention.agentId),
      )
    case MessageEntity_Type.GROUP_MENTION: {
      if (entity.entity.oneofKind !== "groupMention") return null
      const url = groupMentionMdUrl(entity.entity.groupMention.groupId)
      return url ? linkEntity(range, entity, url) : null
    }
    case MessageEntity_Type.THREAD:
      if (entity.entity.oneofKind !== "thread") {
        return null
      }
      return linkEntity(range, entity, threadMdUrl(entity.entity.thread.chatId))
    case MessageEntity_Type.THREAD_TITLE:
      if (entity.entity.oneofKind !== "threadTitle") {
        return null
      }
      return linkEntity(range, entity, threadTitleMdUrl(entity.entity.threadTitle))
    default:
      return null
  }
}

const trimRangeWhitespace = (
  text: string,
  range: { start: number; end: number },
): { start: number; end: number } | null => {
  let start = range.start
  let end = range.end

  while (start < end && /\s/u.test(text[start] ?? "")) {
    start += 1
  }

  while (end > start && /\s/u.test(text[end - 1] ?? "")) {
    end -= 1
  }

  return start < end ? { start, end } : null
}

const linkEntity = (
  range: { start: number; end: number } | null,
  entity: MessageEntity,
  url: string,
): MarkdownEntity | null => {
  if (!range || !representableLink(url)) {
    return null
  }

  const parsed = textUrlEntity({ url, offset: 0, length: 1 })
  if (!parsed || !sameSemanticTarget(entity, parsed)) {
    return null
  }

  return {
    ...range,
    entity,
    open: "[",
    close: `](${escapeLinkUrl(url)})`,
    raw: false,
  }
}

const representableInlineCode = (content: string): boolean => {
  if (content.startsWith("`") || content.endsWith("`")) return false
  if (!/[\r\n]/.test(content)) return true
  const delimiter = codeDelimiter(content), wrapped = delimiter + content + delimiter
  const spans = prepareMarkdownInlineSyntax(wrapped)?.inlineCodes
  return spans?.length === 1 && spans[0]!.start === 0 && spans[0]!.end === wrapped.length
    && spans[0]!.content === content
}

const representableLink = (url: string): boolean => !/[\uD800-\uDFFF]/u.test(url)
  // Space and tab destinations retain the established angle-bracket transport;
  // line breaks and other control bytes have no lossless Markdown destination.
  // oxlint-disable-next-line no-control-regex -- Markdown URL transport rejects these exact control bytes
  && !/[\u0000-\u0008\u000a-\u001f\u007f-\u009f]/u.test(url)

const sameSemanticTarget = (expected: MessageEntity, parsed: MessageEntity): boolean => {
  if (expected.type !== parsed.type || expected.entity.oneofKind !== parsed.entity.oneofKind) return false
  switch (expected.entity.oneofKind) {
    case "textUrl":
      return parsed.entity.oneofKind === "textUrl" && expected.entity.textUrl.url === parsed.entity.textUrl.url
    case "mention":
      return parsed.entity.oneofKind === "mention"
        && expected.entity.mention.userId === parsed.entity.mention.userId
        && expected.entity.mention.agentId === parsed.entity.mention.agentId
    case "groupMention":
      return parsed.entity.oneofKind === "groupMention"
        && expected.entity.groupMention.groupId === parsed.entity.groupMention.groupId
    case "thread":
      return parsed.entity.oneofKind === "thread"
        && expected.entity.thread.chatId === parsed.entity.thread.chatId
    case "threadTitle":
      return parsed.entity.oneofKind === "threadTitle"
        && expected.entity.threadTitle.spaceId === parsed.entity.threadTitle.spaceId
        && expected.entity.threadTitle.title === parsed.entity.threadTitle.title
    default:
      return false
  }
}

const priority = (entity: MarkdownEntity): number => {
  switch (entity.entity.type) {
    case MessageEntity_Type.TEXT_URL:
    case MessageEntity_Type.MENTION:
    case MessageEntity_Type.GROUP_MENTION:
    case MessageEntity_Type.THREAD:
    case MessageEntity_Type.THREAD_TITLE:
      return 0
    case MessageEntity_Type.BOLD:
      return 1
    case MessageEntity_Type.ITALIC:
      return 2
    case MessageEntity_Type.UNDERLINE:
      return 3
    case MessageEntity_Type.STRIKETHROUGH:
      return 4
    case MessageEntity_Type.HIGHLIGHT:
      return 5
    case MessageEntity_Type.CODE:
    case MessageEntity_Type.PRE:
    case MessageEntity_Type.MATH:
      return 6
    default:
      return 9
  }
}

const openSort = (a: MarkdownEntity, b: MarkdownEntity): number => {
  const aLength = a.end - a.start
  const bLength = b.end - b.start
  if (aLength !== bLength) {
    return bLength - aLength
  }
  return priority(a) - priority(b)
}

const closeSort = (a: MarkdownEntity, b: MarkdownEntity): number => {
  const aLength = a.end - a.start
  const bLength = b.end - b.start
  if (aLength !== bLength) {
    return aLength - bLength
  }
  return priority(b) - priority(a)
}
