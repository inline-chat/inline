import { MessageEntity_Type, type MessageEntities, type MessageEntity } from "@inline-chat/protocol/core"
import { boldMd } from "./bold"
import { cleanPreLanguage, codeDelimiter, preFence } from "./code"
import { escapeLinkUrl, escapeMdText } from "./escape"
import { italicMd } from "./italic"
import { mentionMdUrl } from "./mention"
import { contains, hasPartialOverlap, sortEntities, toRange } from "./offsets"
import { policyFor } from "./registry"
import { textUrlEntity } from "./textUrl"
import { threadMdUrl } from "./thread"
import { threadTitleMdUrl } from "./threadTitle"
import type { MarkdownEntity } from "./types"

export const toMd = (text: string, entities: MessageEntities | null | undefined): string => {
  if (!entities?.entities.length) {
    return escapeMdText(text)
  }

  const markdownEntities = normalizeMarkdownEntities(text, entities.entities)
  if (markdownEntities.length === 0) {
    return escapeMdText(text)
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

  for (let index = 0; index < sortedPositions.length; index++) {
    const position = sortedPositions[index]!

    const closing = (ends.get(position) ?? []).sort(closeSort)
    for (const item of closing) {
      result += item.close
      if (item.raw) {
        rawDepth -= 1
      }
    }

    const opening = (starts.get(position) ?? []).sort(openSort)
    for (const item of opening) {
      result += item.open
      if (item.raw) {
        rawDepth += 1
      }
    }

    const next = sortedPositions[index + 1]
    if (next === undefined || next === position) {
      continue
    }

    const slice = text.slice(position, next)
    result += rawDepth > 0 ? slice : escapeMdText(slice)
  }

  return result
}

const normalizeMarkdownEntities = (text: string, entities: MessageEntity[]): MarkdownEntity[] => {
  const candidates = sortEntities(entities)
    .map((entity) => toMarkdownEntity(text, entity))
    .filter((entity): entity is MarkdownEntity => entity !== null)

  const accepted: MarkdownEntity[] = []
  for (const candidate of candidates) {
    const conflicts = accepted.some((item) => hasPartialOverlap(candidate, item))
    if (conflicts) {
      continue
    }

    const insideRaw = accepted.some((item) => item.raw && contains(item, candidate))
    if (insideRaw) {
      continue
    }

    accepted.push(candidate)
  }

  return accepted
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
    case MessageEntity_Type.CODE: {
      const delimiter = codeDelimiter(text.slice(range.start, range.end))
      return { ...range, entity, open: delimiter, close: delimiter, raw: true }
    }
    case MessageEntity_Type.PRE: {
      const content = text.slice(range.start, range.end)
      const fence = preFence(content)
      const language = entity.entity.oneofKind === "pre" ? cleanPreLanguage(entity.entity.pre.language) : ""
      const open = `${fence}${language ? language : ""}\n`
      return { ...range, entity, open, close: fence, raw: true }
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
      return linkEntity(trimRangeWhitespace(text, range), entity, mentionMdUrl(entity.entity.mention.userId))
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
  if (!range) {
    return null
  }

  const parsed = textUrlEntity({ url, offset: 0, length: 1 })
  if (!parsed) {
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

const priority = (entity: MarkdownEntity): number => {
  switch (entity.entity.type) {
    case MessageEntity_Type.TEXT_URL:
    case MessageEntity_Type.MENTION:
    case MessageEntity_Type.THREAD:
    case MessageEntity_Type.THREAD_TITLE:
      return 0
    case MessageEntity_Type.BOLD:
      return 1
    case MessageEntity_Type.ITALIC:
      return 2
    case MessageEntity_Type.CODE:
    case MessageEntity_Type.PRE:
      return 3
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
