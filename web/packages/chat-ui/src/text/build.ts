/**
 * Builds the text render model from a message's text and entities.
 *
 * Rules, matching the Apple clients where they decide (`InlineUI/TextProcessing/
 * ProcessEntities.swift`, `InlineKit/ProtocolHelpers/ProtocolBlockContent.swift`):
 *
 * - An entity is dropped when its type is unknown, its offset or length is not
 *   a safe integer, its offset is negative, its length is not positive, it runs
 *   past the text, or either edge splits a surrogate pair. Edges inside any
 *   other grapheme cluster (a combining mark, a ZWJ emoji sequence, CR LF) are
 *   moved outward to the cluster's edges, so styling never cuts a character.
 * - `pre` becomes a code block. Its text is literal; entities inside it are
 *   ignored. Overlapping `pre` entities: the earliest (then longest) wins.
 * - `blockquote` becomes a quote only when it owns whole lines, is not blank
 *   and does not touch a `pre`; otherwise its text stays as plain text, as
 *   older clients show it. Overlapping quotes: the earliest (then shortest) wins.
 * - `math` with `display` on its own line becomes a math block; other math is
 *   an inline math node. Math inside code is plain code text.
 * - Text between blocks splits into paragraphs at blank lines. A single line
 *   break stays inside a paragraph's text. Leading and trailing line breaks of
 *   each stretch are dropped.
 * - Links, mentions, thread references and bot commands are containers. They
 *   never overlap or nest: sorted by start, then longest, then input order, a
 *   container that overlaps an earlier accepted one is dropped (its text stays,
 *   with its marks). Inline math is accepted before the others.
 * - Marks (bold, italic, underline, strikethrough, highlight, inline code)
 *   overlap freely, inside and outside containers.
 * - A link renders only if `safeLink` accepts it. A `textUrl` to
 *   `inline://user/<id>` is a mention and one to `inline://chat/<id>` a thread
 *   reference, as on the Mac. A URL entity whose text is a phone number is a
 *   phone link.
 *
 * Malformed input never throws: it degrades to plain text.
 */

import type { EntityType } from "@inline/core-protocol"
import { parseInlineId, type ChatID, type SpaceID, type UserID } from "@inline/ids"
import { addTallies, emptyTally, leafDirection, tallyDirection, tallyToDirection, type DirectionTally } from "../direction"
import { appLinkQuery, isPhoneNumberCandidate, safeLink, type SafeLink, type SafeLinkOptions } from "../links"
import { graphemeEndAtOrAfter, graphemeStartAtOrBefore, splitsSurrogatePair } from "./graphemes"
import {
  markOrder,
  type BlockNode,
  type CodeBlockNode,
  type InlineNode,
  type LinkSource,
  type Mark,
  type MathBlockNode,
  type MentionTarget,
  type ParagraphNode,
  type QuoteNode,
  type TextDocument,
  type TextRun,
  type ThreadTarget,
} from "./types"

export type TextRenderOptions = {
  /** Render phone numbers as `tel:` links (the Mac's `renderPhoneNumbers`). Default true. */
  readonly phoneNumbers?: boolean
  /** Passed to `safeLink` for every link, for example a development app origin. */
  readonly links?: Omit<SafeLinkOptions, "bareDomain">
}

// MARK: - Entity normalization

const entityTypes: ReadonlySet<string> = new Set<EntityType>([
  "mention",
  "url",
  "textUrl",
  "email",
  "bold",
  "italic",
  "usernameMention",
  "code",
  "pre",
  "phoneNumber",
  "thread",
  "threadTitle",
  "botCommand",
  "groupMention",
  "underline",
  "strikethrough",
  "highlight",
  "math",
  "blockquote",
])

type Span = {
  readonly type: EntityType
  readonly start: number
  readonly end: number
  readonly index: number
  readonly entity: Readonly<Record<string, unknown>>
}

const normalizeEntities = (text: string, entities: unknown): Span[] => {
  if (!Array.isArray(entities) || entities.length === 0) return []
  const spans: Span[] = []
  const length = text.length
  for (let index = 0; index < entities.length; index += 1) {
    const raw: unknown = entities[index]
    if (raw === null || typeof raw !== "object") continue
    const entity = raw as Record<string, unknown>
    const type = entity.type
    const offset = entity.offset
    const size = entity.length
    if (typeof type !== "string" || !entityTypes.has(type)) continue
    if (typeof offset !== "number" || typeof size !== "number") continue
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(size)) continue
    if (offset < 0 || size <= 0 || offset > length || size > length - offset) continue
    const start = offset
    const end = offset + size
    if (splitsSurrogatePair(text, start) || splitsSurrogatePair(text, end)) continue
    spans.push({
      type: type as EntityType,
      start: graphemeStartAtOrBefore(text, start),
      end: graphemeEndAtOrAfter(text, end),
      index,
      entity,
    })
  }
  return spans
}

const overlaps = (a: { start: number; end: number }, b: { start: number; end: number }): boolean =>
  a.start < b.end && b.start < a.end

// MARK: - Lines

const isBreak = (unit: number): boolean => unit === 10 || unit === 13

const lineStart = (text: string, offset: number): number => {
  let cursor = offset
  while (cursor > 0 && !isBreak(text.charCodeAt(cursor - 1))) cursor -= 1
  return cursor
}

const lineEnd = (text: string, offset: number): number => {
  let cursor = offset
  while (cursor < text.length && !isBreak(text.charCodeAt(cursor))) cursor += 1
  return cursor
}

const consumeLineBreak = (text: string, offset: number): number => {
  if (text.charCodeAt(offset) === 13 && text.charCodeAt(offset + 1) === 10) return offset + 2
  return offset < text.length && isBreak(text.charCodeAt(offset)) ? offset + 1 : offset
}

const whitespaceOnly = /^\s*$/u
const isBlank = (text: string, start: number, end: number): boolean => whitespaceOnly.test(text.slice(start, end))

const lineBreaksBetween = (text: string, start: number, end: number): number => {
  let count = 0
  for (let i = start; i < end; i += 1) {
    const unit = text.charCodeAt(i)
    if (unit === 10) count += 1
    else if (unit === 13 && text.charCodeAt(i + 1) !== 10) count += 1
  }
  return count
}

// MARK: - Marks

const markForType: Partial<Record<EntityType, Mark>> = {
  bold: "bold",
  italic: "italic",
  underline: "underline",
  strikethrough: "strikethrough",
  highlight: "highlight",
  code: "code",
}

const markBit: Record<Mark, number> = { bold: 1, italic: 2, underline: 4, strikethrough: 8, highlight: 16, code: 32, find: 64 }
const internedMarks = new Map<number, readonly Mark[]>()

/** The canonical, shared mark array for a bit set. */
const marksFor = (bits: number): readonly Mark[] => {
  const existing = internedMarks.get(bits)
  if (existing) return existing
  const marks = Object.freeze(markOrder.filter((mark) => (bits & markBit[mark]) !== 0))
  internedMarks.set(bits, marks)
  return marks
}

export const noMarks: readonly Mark[] = marksFor(0)

/** The interned mark array for `marks` plus `mark`. */
export const marksWith = (marks: readonly Mark[], mark: Mark): readonly Mark[] => {
  let bits = markBit[mark]
  for (const existing of marks) bits |= markBit[existing] ?? 0
  return marksFor(bits)
}

// MARK: - Containers

type ContainerSpec =
  | { readonly kind: "link"; readonly source: LinkSource; readonly link: SafeLink }
  | { readonly kind: "mention"; readonly target: MentionTarget }
  | { readonly kind: "threadRef"; readonly target: ThreadTarget }
  | { readonly kind: "botCommand"; readonly command: string; readonly botUserId?: UserID }
  | { readonly kind: "math" }

type Placed = { readonly start: number; readonly end: number; readonly index: number; readonly spec: ContainerSpec }

const positiveId = <T>(value: unknown): T | undefined =>
  parseInlineId(value, { positive: true }) as T | undefined

const nonNegativeId = <T>(value: unknown): T | undefined => {
  const id = parseInlineId(value)
  return id !== undefined && !id.startsWith("-") ? (id as T) : undefined
}

const usernamePattern = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$/

/** A `textUrl` target as the Mac reads it: a mention, a thread reference, or a link. */
const textUrlSpec = (link: SafeLink, visible: string): ContainerSpec => {
  if (link.kind !== "app" || link.form !== "deepLink") return { kind: "link", source: "textUrl", link }
  if (link.host === "user" && link.path.length <= 1) {
    const userId = positiveId<UserID>(link.path[0]) ?? positiveId<UserID>(appLinkQuery(link, ["id", "user_id"]))
    if (userId) {
      const agentId = positiveId<string>(appLinkQuery(link, ["agent_id"]))
      return { kind: "mention", target: agentId ? { kind: "user", userId, agentId } : { kind: "user", userId } }
    }
  }
  if (
    (link.host === "chat" || link.host === "thread") &&
    link.path.length <= 1 &&
    !link.href.includes("#") &&
    appLinkQuery(link, ["message_id", "messageid"]) === undefined &&
    (link.path.length === 0 || positiveId(link.path[0]) !== undefined)
  ) {
    const chatId = positiveId<ChatID>(appLinkQuery(link, ["id", "chat_id"])) ?? positiveId<ChatID>(link.path[0])
    if (chatId) return { kind: "threadRef", target: { kind: "chat", chatId } }
    if (link.host === "thread") {
      const spaceId = nonNegativeId<SpaceID>(appLinkQuery(link, ["space_id"]))
      const title = (appLinkQuery(link, ["title"]) ?? visible).trim()
      if (spaceId !== undefined && title.length > 0) return { kind: "threadRef", target: { kind: "title", spaceId, title } }
    }
  }
  return { kind: "link", source: "textUrl", link }
}

const containerSpec = (span: Span, text: string, options: TextRenderOptions): ContainerSpec | undefined => {
  const visible = text.slice(span.start, span.end)
  const entity = span.entity
  const linkOptions = options.links ?? {}
  const phones = options.phoneNumbers !== false
  switch (span.type) {
    case "url": {
      if (isPhoneNumberCandidate(visible)) {
        if (!phones) return undefined
        const link = safeLink(`tel:${visible.trim()}`)
        return link ? { kind: "link", source: "url", link } : undefined
      }
      const link = safeLink(visible, { ...linkOptions, bareDomain: true })
      return link ? { kind: "link", source: "url", link } : undefined
    }
    case "textUrl": {
      const link = safeLink(entity.url, { ...linkOptions, bareDomain: true })
      return link ? textUrlSpec(link, visible) : undefined
    }
    case "email": {
      const link = safeLink(`mailto:${visible.trim()}`)
      return link ? { kind: "link", source: "email", link } : undefined
    }
    case "phoneNumber": {
      if (!phones) return undefined
      const link = safeLink(`tel:${visible.trim()}`)
      return link ? { kind: "link", source: "phoneNumber", link } : undefined
    }
    case "mention": {
      const userId = positiveId<UserID>(entity.userId)
      if (!userId) return undefined
      const agentId = positiveId<string>(entity.agentId)
      return { kind: "mention", target: agentId ? { kind: "user", userId, agentId } : { kind: "user", userId } }
    }
    case "usernameMention": {
      const username = visible.startsWith("@") ? visible.slice(1) : visible
      return usernamePattern.test(username) ? { kind: "mention", target: { kind: "username", username } } : undefined
    }
    case "groupMention": {
      const groupId = positiveId<string>(entity.groupId)
      return { kind: "mention", target: groupId ? { kind: "group", groupId } : { kind: "group" } }
    }
    case "thread": {
      const chatId = positiveId<ChatID>(entity.chatId)
      return chatId ? { kind: "threadRef", target: { kind: "chat", chatId } } : undefined
    }
    case "threadTitle": {
      const spaceId = nonNegativeId<SpaceID>(entity.spaceId)
      const title = typeof entity.title === "string" ? entity.title.trim() : ""
      return spaceId !== undefined && title.length > 0
        ? { kind: "threadRef", target: { kind: "title", spaceId, title } }
        : undefined
    }
    case "botCommand": {
      const botUserId = positiveId<UserID>(entity.botUserId)
      return botUserId ? { kind: "botCommand", command: visible, botUserId } : { kind: "botCommand", command: visible }
    }
    default:
      return undefined
  }
}

// MARK: - Inline building

type MutableRun = { kind: "text"; key: string; start: number; end: number; text: string; marks: readonly Mark[] }
type MutableContainer = Placed & { children: MutableRun[] }

const pushRun = (list: MutableRun[] | InlineNode[], run: MutableRun, text: string): void => {
  const last = list[list.length - 1]
  if (last && last.kind === "text" && last.end === run.start && last.marks === run.marks) {
    const merged = last as MutableRun
    merged.end = run.end
    merged.text = text.slice(merged.start, merged.end)
    return
  }
  list.push(run)
}

const keyPrefix: Record<ContainerSpec["kind"], string> = {
  link: "l",
  mention: "m",
  threadRef: "r",
  botCommand: "b",
  math: "x",
}

const finishContainer = (container: MutableContainer, text: string): InlineNode => {
  const { start, end, spec } = container
  const key = `${keyPrefix[spec.kind]}${start}`
  const children: readonly TextRun[] = container.children
  switch (spec.kind) {
    case "link":
      return { kind: "link", key, start, end, source: spec.source, link: spec.link, children }
    case "mention":
      return { kind: "mention", key, start, end, target: spec.target, children }
    case "threadRef":
      return { kind: "threadRef", key, start, end, target: spec.target, children }
    case "botCommand":
      return spec.botUserId
        ? { kind: "botCommand", key, start, end, command: spec.command, botUserId: spec.botUserId, children }
        : { kind: "botCommand", key, start, end, command: spec.command, children }
    case "math":
      return { kind: "math", key, start, end, source: text.slice(start, end) }
  }
}

type MarkSpan = { readonly start: number; readonly end: number; readonly bit: number }

const buildInlines = (
  text: string,
  start: number,
  end: number,
  marks: readonly MarkSpan[],
  containers: readonly Placed[],
): InlineNode[] => {
  const localMarks = marks.filter((m) => m.start < end && m.end > start)
  const localContainers = containers
    .filter((c) => c.start < end && c.end > start)
    .map((c) => ({ ...c, start: Math.max(c.start, start), end: Math.min(c.end, end) }))

  if (localMarks.length === 0 && localContainers.length === 0) {
    return [{ kind: "text", key: `t${start}`, start, end, text: text.slice(start, end), marks: noMarks }]
  }

  const cuts = new Set<number>([start, end])
  for (const m of localMarks) {
    cuts.add(Math.max(m.start, start))
    cuts.add(Math.min(m.end, end))
  }
  for (const c of localContainers) {
    cuts.add(c.start)
    cuts.add(c.end)
  }
  const points = [...cuts].sort((a, b) => a - b)

  const nodes: InlineNode[] = []
  let open: MutableContainer | undefined
  let containerIndex = 0
  const close = (): void => {
    if (open) nodes.push(finishContainer(open, text))
    open = undefined
  }

  for (let i = 0; i + 1 < points.length; i += 1) {
    const from = points[i] ?? start
    const to = points[i + 1] ?? end
    while (containerIndex < localContainers.length && (localContainers[containerIndex]?.end ?? 0) <= from) {
      containerIndex += 1
    }
    const candidate = localContainers[containerIndex]
    const inside = candidate !== undefined && candidate.start <= from && to <= candidate.end ? candidate : undefined
    if (open && (inside === undefined || open.start !== inside.start)) close()

    if (inside?.spec.kind === "math") {
      if (!open) open = { ...inside, children: [] }
      continue
    }

    let bits = 0
    for (const m of localMarks) if (m.start <= from && to <= m.end) bits |= m.bit
    const run: MutableRun = { kind: "text", key: `t${from}`, start: from, end: to, text: text.slice(from, to), marks: marksFor(bits) }

    if (inside) {
      if (!open) open = { ...inside, children: [] }
      pushRun(open.children, run, text)
    } else {
      pushRun(nodes, run, text)
    }
  }
  close()
  return nodes
}

// MARK: - Document

const languagePattern = /^[A-Za-z0-9_+#.-]{1,32}$/

type Section =
  | { readonly kind: "codeBlock"; readonly start: number; readonly end: number; readonly language: string | undefined }
  | { readonly kind: "quote"; readonly start: number; readonly end: number }
  | { readonly kind: "mathBlock"; readonly start: number; readonly end: number }

type ParagraphDraft = { start: number; end: number; children: InlineNode[]; tally: DirectionTally; blankLinesBefore: number }

/** Paragraphs of `text[from, to)`, split at blank lines. */
const paragraphRanges = (text: string, from: number, to: number): { start: number; end: number }[] => {
  const ranges: { start: number; end: number }[] = []
  let line = from
  let paragraphStart = -1
  let paragraphEnd = -1
  while (line < to) {
    const end = Math.min(lineEnd(text, line), to)
    if (isBlank(text, line, end)) {
      if (paragraphStart >= 0) ranges.push({ start: paragraphStart, end: paragraphEnd })
      paragraphStart = -1
    } else {
      if (paragraphStart < 0) paragraphStart = line
      paragraphEnd = end
    }
    line = end < to ? Math.min(consumeLineBreak(text, end), to) : to
    if (line === end) break
  }
  if (paragraphStart >= 0) ranges.push({ start: paragraphStart, end: paragraphEnd })
  return ranges
}

/**
 * Builds the render model for a message's text and entities. Pure; never
 * throws. Non-string text renders as empty; a non-array `entities` as none.
 */
export const buildTextDocument = (text: unknown, entities?: unknown, options: TextRenderOptions = {}): TextDocument => {
  const source = typeof text === "string" ? text : ""
  const spans = normalizeEntities(source, entities)
  const byOrder = (a: Span, b: Span): number => a.start - b.start || b.end - a.end || a.index - b.index

  // Code blocks.
  const allPre = spans.filter((s) => s.type === "pre")
  const codeSpans = spans.filter((s) => s.type === "code" || s.type === "pre")
  const pres: Span[] = []
  for (const span of [...allPre].sort(byOrder)) {
    if (!pres.some((p) => overlaps(p, span))) pres.push(span)
  }

  // Quotes: whole lines, not blank, clear of code blocks. Earliest, then shortest.
  const quotes: Span[] = []
  const quoteCandidates = spans
    .filter(
      (s) =>
        s.type === "blockquote" &&
        lineStart(source, s.start) === s.start &&
        lineEnd(source, s.end) === s.end &&
        !isBlank(source, s.start, s.end) &&
        !allPre.some((p) => overlaps(p, s)),
    )
    .sort((a, b) => a.start - b.start || a.end - b.end || a.index - b.index)
  for (const span of quoteCandidates) {
    const last = quotes[quotes.length - 1]
    if (!last || span.start >= last.end) quotes.push(span)
  }

  // Math: display on its own line becomes a block; the rest is inline. Never inside code.
  const mathSpans = spans.filter((s) => s.type === "math" && !codeSpans.some((c) => overlaps(c, s)))
  const displayMath: Span[] = []
  for (const span of [...mathSpans].sort(byOrder)) {
    if (span.entity.display !== true) continue
    const prefix = source.slice(lineStart(source, span.start), span.start)
    const suffixEnd = lineEnd(source, span.end)
    if (prefix.length > 3 || !/^ *$/.test(prefix) || !isBlank(source, span.end, suffixEnd)) continue
    if (quotes.some((q) => overlaps(q, span)) || pres.some((p) => overlaps(p, span))) continue
    if (displayMath.some((d) => overlaps(d, span))) continue
    displayMath.push(span)
  }

  // Containers: inline math first, then the rest in order; no overlaps.
  const placed: Placed[] = []
  for (const span of mathSpans) {
    if (displayMath.includes(span) || placed.some((p) => overlaps(p, span))) continue
    placed.push({ start: span.start, end: span.end, index: span.index, spec: { kind: "math" } })
  }
  for (const span of [...spans].sort(byOrder)) {
    if (span.type === "math" || markForType[span.type] || span.type === "pre" || span.type === "blockquote") continue
    if (placed.some((p) => overlaps(p, span))) continue
    const spec = containerSpec(span, source, options)
    if (spec) placed.push({ start: span.start, end: span.end, index: span.index, spec })
  }
  placed.sort((a, b) => a.start - b.start)

  const markSpans: MarkSpan[] = []
  for (const span of spans) {
    const mark = markForType[span.type]
    if (mark) markSpans.push({ start: span.start, end: span.end, bit: markBit[mark] })
  }

  const sections: Section[] = [
    ...pres.map((s): Section => {
      const language = typeof s.entity.language === "string" ? s.entity.language.trim() : ""
      return { kind: "codeBlock", start: s.start, end: s.end, language: languagePattern.test(language) ? language : undefined }
    }),
    ...quotes.map((s): Section => ({ kind: "quote", start: s.start, end: s.end })),
    ...displayMath.map((s): Section => ({ kind: "mathBlock", start: s.start, end: s.end })),
  ].sort((a, b) => a.start - b.start)

  // Walk the flow.
  type Draft =
    | (ParagraphDraft & { kind: "paragraph" })
    | { kind: "codeBlock"; start: number; end: number; language: string | undefined; blankLinesBefore: number }
    | { kind: "mathBlock"; start: number; end: number; blankLinesBefore: number }
    | { kind: "quote"; start: number; end: number; children: ParagraphDraft[]; blankLinesBefore: number }

  const drafts: Draft[] = []
  let previousEnd: number | undefined
  const gap = (start: number): number =>
    previousEnd === undefined ? 0 : Math.max(0, lineBreaksBetween(source, previousEnd, start) - 1)

  const paragraphs = (from: number, to: number, gapFrom: number | undefined): ParagraphDraft[] => {
    let last = gapFrom
    return paragraphRanges(source, from, to).map(({ start, end }) => {
      const blankLinesBefore = last === undefined ? 0 : Math.max(0, lineBreaksBetween(source, last, start) - 1)
      last = end
      return {
        start,
        end,
        blankLinesBefore,
        children: buildInlines(source, start, end, markSpans, placed),
        tally: tallyDirection(source, start, end),
      }
    })
  }

  const flow = (from: number, to: number): void => {
    for (const paragraph of paragraphs(from, to, previousEnd)) {
      drafts.push({ kind: "paragraph", ...paragraph })
      previousEnd = paragraph.end
    }
  }

  let cursor = 0
  for (const section of sections) {
    switch (section.kind) {
      case "codeBlock":
        flow(cursor, section.start)
        drafts.push({ ...section, blankLinesBefore: gap(section.start) })
        cursor = consumeLineBreak(source, section.end)
        break
      case "mathBlock":
        flow(cursor, lineStart(source, section.start))
        drafts.push({ ...section, blankLinesBefore: gap(section.start) })
        cursor = consumeLineBreak(source, lineEnd(source, section.end))
        break
      case "quote":
        flow(cursor, section.start)
        drafts.push({
          kind: "quote",
          start: section.start,
          end: section.end,
          blankLinesBefore: gap(section.start),
          children: paragraphs(section.start, section.end, undefined),
        })
        cursor = consumeLineBreak(source, section.end)
        break
    }
    previousEnd = section.end
  }
  flow(cursor, source.length)

  // Directions: the message by word majority over its prose; paragraphs by
  // their own majority unless it is not decisive.
  let messageTally = emptyTally
  for (const draft of drafts) {
    if (draft.kind === "paragraph") messageTally = addTallies(messageTally, draft.tally)
    else if (draft.kind === "quote") for (const child of draft.children) messageTally = addTallies(messageTally, child.tally)
  }
  const messageDir = tallyToDirection(messageTally)

  const paragraphNode = (draft: ParagraphDraft): ParagraphNode => ({
    kind: "paragraph",
    key: `p${draft.start}`,
    start: draft.start,
    end: draft.end,
    blankLinesBefore: draft.blankLinesBefore,
    dir: leafDirection(draft.tally, messageDir),
    children: draft.children,
  })

  const blocks: BlockNode[] = drafts.map((draft): BlockNode => {
    switch (draft.kind) {
      case "paragraph":
        return paragraphNode(draft)
      case "codeBlock":
        return {
          kind: "codeBlock",
          key: `pre${draft.start}`,
          start: draft.start,
          end: draft.end,
          blankLinesBefore: draft.blankLinesBefore,
          language: draft.language,
          text: source.slice(draft.start, draft.end),
        } satisfies CodeBlockNode
      case "mathBlock":
        return {
          kind: "mathBlock",
          key: `mb${draft.start}`,
          start: draft.start,
          end: draft.end,
          blankLinesBefore: draft.blankLinesBefore,
          source: source.slice(draft.start, draft.end),
        } satisfies MathBlockNode
      case "quote": {
        const tally = draft.children.reduce((sum, child) => addTallies(sum, child.tally), emptyTally)
        return {
          kind: "quote",
          key: `q${draft.start}`,
          start: draft.start,
          end: draft.end,
          blankLinesBefore: draft.blankLinesBefore,
          dir: tallyToDirection(tally),
          children: draft.children.map(paragraphNode),
        } satisfies QuoteNode
      }
    }
  })

  return { kind: "document", text: source, dir: messageDir, blocks }
}

