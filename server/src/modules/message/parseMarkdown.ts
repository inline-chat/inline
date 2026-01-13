import { MessageEntity, MessageEntity_Type } from "@in/protocol/core"

export type ParsedMarkdown = {
  text: string
  entities: MessageEntity[]
}

type Match = {
  start: number
  end: number
  content: string
  type: MessageEntity_Type
  url?: string
  language?: string
}

/**
 * Parses markdown text and extracts entities.
 * Supported patterns: bold, italic, inline code, code blocks, links.
 */
export function parseMarkdown(input: string): ParsedMarkdown {
  if (!input) {
    return { text: "", entities: [] }
  }

  // Find all matches first, then process in order
  const matches: Match[] = []

  // 1. Code blocks: ```lang\ncode\n``` (highest priority - content is protected)
  findCodeBlocks(input, matches)

  // 2. Inline code: `code` (high priority - content is protected)
  findInlineCode(input, matches)

  // 3. Links: [text](url)
  findLinks(input, matches)

  // 4. Emails: example@domain.com
  findEmails(input, matches)

  // 5. Bold: **text** or __text__
  findBold(input, matches)

  // 6. Italic: *text* or _text_
  findItalic(input, matches)

  // Remove overlapping matches (earlier patterns win)
  const filteredMatches = removeOverlaps(matches)

  // Sort by start position
  filteredMatches.sort((a, b) => a.start - b.start)

  // Build output text and entities
  let result = ""
  let lastIndex = 0
  const entities: MessageEntity[] = []

  for (const match of filteredMatches) {
    // Add text before this match
    result += input.slice(lastIndex, match.start)

    // Only create entity if there's actual content
    if (match.content.length > 0) {
      // Record entity with offset in output text
      const offset = result.length
      entities.push(createEntity(match, offset))
      // Add the content (without markdown syntax)
      result += match.content
    }
    // Always consume the matched syntax
    lastIndex = match.end
  }

  // Add remaining text
  result += input.slice(lastIndex)

  return { text: result, entities }
}

function createEntity(match: Match, offset: number): MessageEntity {
  const entity: MessageEntity = {
    offset: BigInt(offset),
    length: BigInt(match.content.length),
    type: match.type,
    entity: { oneofKind: undefined },
  }

  if (match.type === MessageEntity_Type.TEXT_URL && match.url) {
    entity.entity = {
      oneofKind: "textUrl",
      textUrl: { url: match.url },
    }
  } else if (match.type === MessageEntity_Type.PRE && match.language !== undefined) {
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

function findCodeBlocks(text: string, matches: Match[]): void {
  const regex = /```(\w*)\n([\s\S]*?)```/g
  let match: RegExpExecArray | null

  while ((match = regex.exec(text)) !== null) {
    const language = match[1] ?? ""
    const code = match[2] ?? ""
    const trimmedCode = code.trim()

    // Always add match to block other patterns from matching inside
    // Even empty code blocks need to consume the syntax
    matches.push({
      start: match.index,
      end: match.index + match[0].length,
      content: trimmedCode,
      type: MessageEntity_Type.PRE,
      language,
    })
  }
}

function findInlineCode(text: string, matches: Match[]): void {
  // Inline code should not span newlines - that would be a code block
  const regex = /`([^`\n]+)`/g
  let match: RegExpExecArray | null

  while ((match = regex.exec(text)) !== null) {
    const code = match[1] ?? ""

    if (code.length > 0) {
      matches.push({
        start: match.index,
        end: match.index + match[0].length,
        content: code,
        type: MessageEntity_Type.CODE,
      })
    }
  }
}

function findLinks(text: string, matches: Match[]): void {
  const regex = /\[([^\]]+)\]\(([^)]+)\)/g
  let match: RegExpExecArray | null

  while ((match = regex.exec(text)) !== null) {
    const linkText = match[1] ?? ""
    const url = match[2] ?? ""

    if (linkText.length > 0 && url.length > 0) {
      matches.push({
        start: match.index,
        end: match.index + match[0].length,
        content: linkText,
        type: MessageEntity_Type.TEXT_URL,
        url,
      })
    }
  }
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
        type: MessageEntity_Type.EMAIL,
      })
    }
  }
}

function findBold(text: string, matches: Match[]): void {
  const regex = /(\*\*|__)(.+?)\1/g
  let match: RegExpExecArray | null

  while ((match = regex.exec(text)) !== null) {
    const content = match[2] ?? ""

    if (content.trim().length > 0) {
      matches.push({
        start: match.index,
        end: match.index + match[0].length,
        content,
        type: MessageEntity_Type.BOLD,
      })
    }
  }
}

function findItalic(text: string, matches: Match[]): void {
  // Match *text* or _text_ but not ** or __
  const regex = /(?<!\*)\*(?!\*)(.+?)\*(?!\*)|(?<!_)_(?!_)(.+?)_(?!_)/g
  let match: RegExpExecArray | null

  while ((match = regex.exec(text)) !== null) {
    const content = match[1] || match[2] || ""

    if (content.trim().length > 0) {
      matches.push({
        start: match.index,
        end: match.index + match[0].length,
        content,
        type: MessageEntity_Type.ITALIC,
      })
    }
  }
}
