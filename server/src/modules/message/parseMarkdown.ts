import { MessageEntity, MessageEntity_Type } from "@inline-chat/protocol/core"

export type ParsedMarkdown = {
  text: string
  entities: MessageEntity[]
}

export type ParsedMarkdownWithSourceMap = ParsedMarkdown & {
  /** UTF-16 source boundary to UTF-16 output boundary, including the final boundary. */
  sourceToOutput: number[]
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

  const output: string[] = []
  let cursor = 0
  let fence: MarkdownFence | undefined

  while (cursor < input.length) {
    const line = readLine(input, cursor)
    let value = line.value

    if (fence) {
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
  input = normalizeMarkdownInput(input)
  if (!input) {
    return { text: "", entities: [], sourceToOutput: [0] }
  }

  // Find all matches first, then process in order
  const matches: Match[] = []

  // Inline's authorized structural extension is presentation syntax, not
  // user-visible fallback text. Preserve a readable indented projection for
  // clients that only consume Message.text.
  findBlockExtensionSyntax(input, matches)

  // Backslash escapes consume the slash and protect the escaped punctuation
  // from lower-priority structural matches.
  findEscapes(input, matches)

  // 1. Fenced code blocks (highest priority - content is protected)
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
  const sourceToOutput = Array<number>(input.length + 1).fill(0)

  for (const match of filteredMatches) {
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
      // Add the content (without markdown syntax)
      if (match.nestedSourceToOutput) {
        for (let index = 0; index < match.nestedSourceToOutput.length; index++) {
          sourceToOutput[match.contentStart + index] = outputStart + match.nestedSourceToOutput[index]!
        }
      } else {
        mapLiteralBoundaries(sourceToOutput, match.contentStart, match.contentEnd, outputStart)
      }
      result += match.content
    }
    fillCollapsedBoundaries(sourceToOutput, match.contentEnd, match.end, result.length)
    // Always consume the matched syntax
    lastIndex = match.end
  }

  // Add remaining text
  mapLiteralBoundaries(sourceToOutput, lastIndex, input.length, result.length)
  result += input.slice(lastIndex)

  return { text: result, entities, sourceToOutput }
}

function findBlockExtensionSyntax(text: string, matches: Match[]): void {
  let cursor = 0
  let detailsDepth = 0
  let fence: MarkdownFence | undefined

  const remove = (start: number, end: number, replacement = ""): void => {
    matches.push({ start, end, content: replacement, contentStart: end, contentEnd: end })
  }

  while (cursor < text.length) {
    const line = readLine(text, cursor)
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
        ? /^<summary(?: kind="progress")?>.*<\/summary>$/.test(summaryLine.value)
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

    const summary = /^<summary(?: kind="progress")?>(.*)<\/summary>$/.exec(line.value)
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
  options?: { allowedTypes?: Set<MessageEntity_Type> }
): ParsedMarkdownWithSourceMap {
  const parsed = parseMarkdownWithSourceMap(content)

  if (!options?.allowedTypes) {
    return parsed
  }

  return {
    text: parsed.text,
    entities: parsed.entities.filter((entity) => options.allowedTypes?.has(entity.type)),
    sourceToOutput: parsed.sourceToOutput,
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

function findCodeBlocks(text: string, matches: Match[]): void {
  let cursor = 0
  while (cursor < text.length) {
    const openingLine = readLine(text, cursor)
    const opening = parseOpeningFence(openingLine.value)
    if (!opening) {
      cursor = openingLine.next
      continue
    }

    let closingCursor = openingLine.next
    let closingLine: MarkdownLine | undefined
    while (closingCursor < text.length) {
      const candidate = readLine(text, closingCursor)
      if (isClosingFence(candidate.value, opening)) {
        closingLine = candidate
        break
      }
      closingCursor = candidate.next
    }

    // CommonMark treats an opening fence without a closing fence as code
    // through the end of the document. Streaming snapshots need the same
    // top-to-bottom rule so a completed block stays closed and a later open
    // block protects its contents from inline Markdown parsing.
    const contentBoundary = closingLine?.start ?? text.length
    const rawCode = text.slice(openingLine.next, contentBoundary)
    const trimmedCode = rawCode.trim()
    const leadingTrim = rawCode.length - rawCode.trimStart().length
    const trailingTrim = rawCode.length - rawCode.trimEnd().length
    const contentStart = openingLine.next + leadingTrim
    const contentEnd = trimmedCode.length === 0
      ? contentStart
      : openingLine.next + rawCode.length - trailingTrim

    // Always consume the whole fence so lower-priority patterns cannot create
    // entities from code contents. The line ending after the close is literal.
    matches.push({
      // Preserve the legacy parser's leading indentation outside the entity;
      // only the fence itself is syntax in the flat compatibility projection.
      start: openingLine.start + opening.indent,
      end: closingLine?.contentEnd ?? text.length,
      content: trimmedCode,
      contentStart,
      contentEnd,
      type: MessageEntity_Type.PRE,
      language: cleanFenceLanguage(opening.info),
    })
    cursor = closingLine?.next ?? text.length
  }
}

function findInlineCode(text: string, matches: Match[]): void {
  let cursor = 0
  while (cursor < text.length) {
    if (text[cursor] !== "`") {
      cursor += 1
      continue
    }

    const openingStart = cursor
    const delimiterLength = backtickRunLength(text, cursor)
    cursor += delimiterLength
    let candidate = cursor
    let matched = false
    while (candidate < text.length && text[candidate] !== "\n" && text[candidate] !== "\r") {
      if (text[candidate] !== "`") {
        candidate += 1
        continue
      }
      const closingLength = backtickRunLength(text, candidate)
      if (closingLength === delimiterLength || closingLength === delimiterLength * 2) {
        if (candidate > cursor) {
          matches.push({
            start: openingStart,
            end: candidate + delimiterLength,
            content: text.slice(cursor, candidate),
            contentStart: cursor,
            contentEnd: candidate,
            type: MessageEntity_Type.CODE,
          })
        }
        cursor = candidate + delimiterLength
        matched = true
        break
      }
      candidate += closingLength
    }
    if (!matched) cursor = openingStart + delimiterLength
  }
}

function findEscapes(text: string, matches: Match[]): void {
  for (let index = 0; index + 1 < text.length; index++) {
    if (text[index] !== "\\" || !markdownEscapablePunctuation.has(text[index + 1]!)) continue
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

type MarkdownLine = {
  start: number
  contentEnd: number
  next: number
  value: string
}

type MarkdownFence = {
  character: "`" | "~"
  length: number
  info: string
  indent: number
}

function readLine(text: string, start: number): MarkdownLine {
  const newline = text.indexOf("\n", start)
  const rawEnd = newline >= 0 ? newline : text.length
  const contentEnd = rawEnd > start && text[rawEnd - 1] === "\r" ? rawEnd - 1 : rawEnd
  return {
    start,
    contentEnd,
    next: rawEnd < text.length ? rawEnd + 1 : text.length,
    value: text.slice(start, contentEnd),
  }
}

function parseOpeningFence(line: string): MarkdownFence | undefined {
  const match = /^( {0,3})(`{3,}|~{3,})(.*)$/.exec(line)
  const run = match?.[2]
  if (!run) return undefined
  const info = match?.[3] ?? ""
  if (run[0] === "`" && info.includes("`")) return undefined
  return {
    character: run[0] as "`" | "~",
    length: run.length,
    info,
    indent: match?.[1]?.length ?? 0,
  }
}

function isClosingFence(line: string, fence: MarkdownFence): boolean {
  const match = /^ {0,3}(`+|~+)[ \t]*$/.exec(line)
  const run = match?.[1]
  return run?.[0] === fence.character && run.length >= fence.length
}

function normalizeRepeatedClosingFence(line: string, fence: MarkdownFence): string | undefined {
  const match = /^( {0,3})(`+|~+) \((×(?:[2-9]|[1-9]\d+))\)$/.exec(line)
  const run = match?.[2]
  if (!run || run[0] !== fence.character || run.length < fence.length) return undefined
  return `${match[1]}${run}\n(${match[3]})`
}

function cleanFenceLanguage(info: string): string {
  const language = info.trim().split(/[ \t]+/, 1)[0] ?? ""
  return /^[A-Za-z0-9_+.#-]{0,64}$/.test(language) ? language : ""
}

function backtickRunLength(text: string, start: number): number {
  let end = start
  while (text[end] === "`") end += 1
  return end - start
}

const markdownEscapablePunctuation = new Set(
  Array.from("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"),
)

function findLinks(text: string, matches: Match[]): void {
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== "[") {
      continue
    }

    const textEnd = text.indexOf("]", i + 1)
    if (textEnd === -1) {
      continue
    }

    if (text[textEnd + 1] !== "(") {
      continue
    }

    const linkText = text.slice(i + 1, textEnd)
    if (!linkText) {
      continue
    }

    let urlStart = textEnd + 2
    let depth = 1
    let cursor = urlStart
    while (cursor < text.length && depth > 0) {
      const char = text[cursor]
      if (char === "(") {
        depth += 1
      } else if (char === ")") {
        depth -= 1
      }
      cursor += 1
    }

    if (depth !== 0) {
      continue
    }

    const urlEnd = cursor - 1
    const url = text.slice(urlStart, urlEnd)
    if (!url) {
      continue
    }

    const parsedLinkText = parseNestedContent(linkText, {
      allowedTypes: new Set([
        MessageEntity_Type.BOLD,
        MessageEntity_Type.ITALIC,
        MessageEntity_Type.CODE,
        MessageEntity_Type.PRE,
      ]),
    })

    matches.push({
      start: i,
      end: cursor,
      content: parsedLinkText.text,
      contentStart: i + 1,
      contentEnd: textEnd,
      type: MessageEntity_Type.TEXT_URL,
      url,
      nestedEntities: parsedLinkText.entities,
      nestedSourceToOutput: parsedLinkText.sourceToOutput,
    })

    i = cursor - 1
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
        contentStart: match.index,
        contentEnd: match.index + email.length,
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
      const parsedContent = parseNestedContent(content)

      matches.push({
        start: match.index,
        end: match.index + match[0].length,
        content: parsedContent.text,
        contentStart: match.index + (match[1]?.length ?? 0),
        contentEnd: match.index + match[0].length - (match[1]?.length ?? 0),
        type: MessageEntity_Type.BOLD,
        nestedEntities: parsedContent.entities,
        nestedSourceToOutput: parsedContent.sourceToOutput,
      })
    }
  }
}

function findItalic(text: string, matches: Match[]): void {
  // Match *text* or _text_ but not ** or __
  const regex = /(?<!\*)\*(?!\*)(.+?)\*(?!\*)|(?<![\p{L}\p{N}_])_(?!_)(.+?)(?<!_)_(?![\p{L}\p{N}_])/gu
  let match: RegExpExecArray | null

  while ((match = regex.exec(text)) !== null) {
    const content = match[1] || match[2] || ""

    if (content.trim().length > 0) {
      const parsedContent = parseNestedContent(content)

      matches.push({
        start: match.index,
        end: match.index + match[0].length,
        content: parsedContent.text,
        contentStart: match.index + 1,
        contentEnd: match.index + match[0].length - 1,
        type: MessageEntity_Type.ITALIC,
        nestedEntities: parsedContent.entities,
        nestedSourceToOutput: parsedContent.sourceToOutput,
      })
    }
  }
}
