import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { unescapeLinkUrl } from "./escape"
import { detectLiteralEntities } from "./literalDetectors"
import { sortEntities } from "./offsets"
import { textUrlEntity } from "./textUrl"
import type { MarkdownText } from "./types"

type StackItem =
  {
    kind: "format"
    type: MessageEntity_Type.BOLD | MessageEntity_Type.ITALIC
    marker: string
    offset: number
  }

type CodeParseResult = {
  type: MessageEntity_Type.CODE | MessageEntity_Type.PRE
  content: string
  language?: string
  end: number
}

type LinkParseResult = {
  label: string
  url: string
  end: number
}

const allowedLinkLabelEntityTypes = new Set<MessageEntity_Type>([
  MessageEntity_Type.BOLD,
  MessageEntity_Type.ITALIC,
  MessageEntity_Type.CODE,
  MessageEntity_Type.PRE,
])

export const fromMd = (markdown: string): MarkdownText => {
  let text = ""
  const entities: MessageEntity[] = []
  const stack: StackItem[] = []

  for (let i = 0; i < markdown.length; ) {
    const top = stack[stack.length - 1]

    if (top?.kind === "format" && markdown.startsWith(top.marker, i)) {
      closeFormat(top, text.length, entities)
      stack.pop()
      i += top.marker.length
      continue
    }

    if (markdown[i] === "\\" && i + 1 < markdown.length) {
      text += markdown[i + 1]
      i += 2
      continue
    }

    if (markdown[i] === "`") {
      const parsed = readCode(markdown, i)
      if (parsed) {
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
      const link = readMarkdownLink(markdown, i)
      if (link) {
        const offset = text.length
        const label = fromMd(link.label)
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

    if (markdown.startsWith("**", i)) {
      stack.push({ kind: "format", type: MessageEntity_Type.BOLD, marker: "**", offset: text.length })
      i += 2
      continue
    }

    if (markdown[i] === "*") {
      stack.push({ kind: "format", type: MessageEntity_Type.ITALIC, marker: "*", offset: text.length })
      i += 1
      continue
    }

    text += markdown[i]
    i += 1
  }

  text = restoreUnclosedMarkers(text, stack, entities)

  return {
    text,
    entities: {
      entities: detectLiteralEntities(text, sortEntities(entities)),
    },
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

const restoreUnclosedMarkers = (text: string, stack: StackItem[], entities: MessageEntity[]): string => {
  if (stack.length === 0) {
    return text
  }

  let result = text
  let added = 0
  const markers = stack
    .map((item) => ({
      offset: item.offset,
      marker: item.marker,
    }))
    .sort((a, b) => a.offset - b.offset)

  for (const item of markers) {
    const offset = item.offset + added
    result = result.slice(0, offset) + item.marker + result.slice(offset)
    shiftEntities(entities, offset, item.marker.length)
    added += item.marker.length
  }

  return result
}

const shiftEntities = (entities: MessageEntity[], offset: number, amount: number): void => {
  for (const entity of entities) {
    if (Number(entity.offset) >= offset) {
      entity.offset += BigInt(amount)
    }
  }
}

const closeFormat = (item: Extract<StackItem, { kind: "format" }>, end: number, entities: MessageEntity[]): void => {
  const length = end - item.offset
  if (length <= 0) {
    return
  }

  entities.push({
    type: item.type,
    offset: BigInt(item.offset),
    length: BigInt(length),
    entity: { oneofKind: undefined },
  })
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
  if (close === -1) {
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

const readMarkdownLink = (markdown: string, start: number): LinkParseResult | null => {
  return readDoubleBracketLink(markdown, start) ?? readBracketLink(markdown, start)
}

const readDoubleBracketLink = (markdown: string, start: number): LinkParseResult | null => {
  if (!markdown.startsWith("[[", start)) {
    return null
  }

  for (let i = start + 2; i < markdown.length - 2; i++) {
    if (markdown[i] === "\\" && i + 1 < markdown.length) {
      i += 1
      continue
    }

    if (!markdown.startsWith("]](", i)) {
      continue
    }

    const parsedUrl = readLinkUrl(markdown, i + 3)
    if (!parsedUrl) {
      return null
    }

    return {
      label: markdown.slice(start, i + 2),
      url: parsedUrl.url,
      end: parsedUrl.end,
    }
  }

  return null
}

const readBracketLink = (markdown: string, start: number): LinkParseResult | null => {
  let depth = 1

  for (let i = start + 1; i < markdown.length; i++) {
    const char = markdown[i]

    if (char === "\\" && i + 1 < markdown.length) {
      i += 1
      continue
    }

    if (char === "[") {
      depth += 1
      continue
    }

    if (char !== "]") {
      continue
    }

    depth -= 1
    if (depth !== 0) {
      continue
    }

    if (markdown[i + 1] !== "(") {
      return null
    }

    const parsedUrl = readLinkUrl(markdown, i + 2)
    if (!parsedUrl) {
      return null
    }

    return {
      label: markdown.slice(start + 1, i),
      url: parsedUrl.url,
      end: parsedUrl.end,
    }
  }

  return null
}

const readLinkUrl = (markdown: string, start: number): { url: string; end: number } | null => {
  let url = ""
  let depth = 1

  for (let i = start; i < markdown.length; i++) {
    const char = markdown[i]

    if (char === "\\" && i + 1 < markdown.length) {
      url += markdown[i]
      url += markdown[i + 1]
      i += 1
      continue
    }

    if (char === "(") {
      depth += 1
      url += char
      continue
    }

    if (char === ")") {
      depth -= 1
      if (depth === 0) {
        return { url: unescapeLinkUrl(url), end: i + 1 }
      }
      url += char
      continue
    }

    url += char
  }

  return null
}
