import {
  MessageEntity_Type,
  RichCollageLayout,
  RichDirection,
  RichHorizontalAlign,
  RichTextStyle,
  RichVerticalAlign,
  type MessageEntities,
  type MessageEntity,
  type RichBlock,
  type RichListItemBlock,
  type RichMediaRef,
  type RichMessage,
  type RichTableCell,
  type RichTableRow,
  type RichText,
} from "@inline-chat/protocol/core"

export const richTextLimits = {
  maxTextLength: 32_768,
  maxBlocks: 500,
  maxDepth: 16,
  maxMedia: 50,
  maxUrlLength: 2_048,
  maxLanguageLength: 40,
  maxTableRows: 100,
  maxTableColumns: 20,
} as const

export class RichTextValidationError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "RichTextValidationError"
  }
}

type RenderedRichMessage = {
  text: string
  entities: MessageEntities | undefined
}

type InlineParseOptions = {
  styles?: RichTextStyle[]
  depth?: number
}

type RenderContext = {
  text: string
  entities: MessageEntity[]
}

type NormalizeOptions = {
  fallbackText?: string
  allowThinking?: boolean
}

type BlockBudget = {
  count: number
}

type NormalizeBlockContext = {
  depth: number
  path: number[]
  allowThinking: boolean
  blockBudget: BlockBudget
}

export type MediaDependency = {
  blockId: string
  blockPath: string
  sortOrder: number
  kind: "photo" | "video" | "document" | "voice" | "public_url"
  ref: RichMediaRef
}

const rtlPattern = /[\u0590-\u05ff\u0600-\u06ff\u0750-\u077f\u08a0-\u08ff\ufb50-\ufdff\ufe70-\ufeff]/
const ltrPattern = /[A-Za-z]/
const fencePattern = /^([ \t]*)(`{3,}|~{3,})([^`]*)$/
const headingPattern = /^(#{1,6})[ \t]+(.+?)#*[ \t]*$/
const unorderedListPattern = /^([ \t]*)([-*+])[ \t]+(.+)$/
const orderedListPattern = /^([ \t]*)(\d{1,9})[.)][ \t]+(.+)$/
const taskListMarkerPattern = /^\[([ xX])\][ \t]+([\s\S]*)$/
const dividerPattern = /^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$/
const tableDelimiterPattern = /^[ \t]*\|?[ \t]*:?-{3,}:?[ \t]*(?:\|[ \t]*:?-{3,}:?[ \t]*)+\|?[ \t]*$/

export function parseRichMarkdown(text: string): RichMessage {
  const source = normalizeInputText(text)
  assertTextLength(source)

  const lines = source.split("\n")
  const blocks: RichBlock[] = []
  let index = 0

  while (index < lines.length) {
    const line = lines[index] ?? ""

    if (isBlank(line)) {
      index += 1
      continue
    }

    const details = parseDetails(lines, index)
    if (details) {
      pushRichBlock(blocks, details.block)
      index = details.nextIndex
      continue
    }

    const expandableQuote = parseExpandableBlockquote(lines, index)
    if (expandableQuote) {
      pushRichBlock(blocks, expandableQuote.block)
      index = expandableQuote.nextIndex
      continue
    }

    const table = parseTable(lines, index)
    if (table) {
      pushRichBlock(blocks, table.block)
      index = table.nextIndex
      continue
    }

    const math = parseDisplayMath(lines, index)
    if (math) {
      pushRichBlock(blocks, math.block)
      index = math.nextIndex
      continue
    }

    const image = parseImageBlock(line)
    if (image) {
      pushRichBlock(blocks, image)
      index += 1
      continue
    }

    const fence = line.match(fencePattern)
    if (fence) {
      const parsed = parseFence(lines, index, fence)
      pushRichBlock(blocks, parsed.block)
      index = parsed.nextIndex
      continue
    }

    const heading = line.match(headingPattern)
    if (heading) {
      const text = heading[2]?.trim() ?? ""
      pushRichBlock(blocks, headingBlock(text, heading[1]?.length ?? 1))
      index += 1
      continue
    }

    if (dividerPattern.test(line)) {
      pushRichBlock(blocks, dividerBlock())
      index += 1
      continue
    }

    if (line.trimStart().startsWith(">")) {
      const parsed = parseQuote(lines, index)
      pushRichBlock(blocks, parsed.block)
      index = parsed.nextIndex
      continue
    }

    if (unorderedListPattern.test(line) || orderedListPattern.test(line)) {
      const parsed = parseList(lines, index)
      pushRichBlock(blocks, parsed.block)
      index = parsed.nextIndex
      continue
    }

    const parsed = parseParagraph(lines, index)
    pushRichBlock(blocks, parsed.block)
    index = parsed.nextIndex
  }

  return normalizeRichMessage({
    blocks,
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText: "",
    version: 1,
  })
}

export function normalizeRichMessage(message: RichMessage, fallbackText?: string): RichMessage
export function normalizeRichMessage(message: RichMessage, options?: NormalizeOptions): RichMessage
export function normalizeRichMessage(message: RichMessage, fallbackOrOptions?: string | NormalizeOptions): RichMessage {
  const options: NormalizeOptions =
    typeof fallbackOrOptions === "string" ? { fallbackText: fallbackOrOptions } : (fallbackOrOptions ?? {})
  const blockBudget: BlockBudget = { count: 0 }
  const blocks = normalizeBlocks(message.blocks ?? [], {
    depth: 0,
    path: [],
    allowThinking: options.allowThinking ?? false,
    blockBudget,
  })
  assertMediaCount(blocks)
  const rendered = renderRichBlocks(blocks)
  const suppliedFallback = options.fallbackText ?? message.fallbackText
  const fallback = rendered.text || (blocks.length > 0 ? normalizeInputText(suppliedFallback).trim() : "")
  assertTextLength(fallback)

  return {
    blocks,
    direction: normalizeDirection(message.direction),
    fallbackText: fallback,
    version: message.version > 0 ? message.version : 1,
  }
}

export function renderRichMessage(message: RichMessage): RenderedRichMessage {
  const rendered = renderRichBlocks(message.blocks ?? [])
  return {
    text: message.fallbackText || rendered.text,
    entities: rendered.entities,
  }
}

export function entitiesFromRichMessage(message: RichMessage): MessageEntities | undefined {
  return renderRichBlocks(message.blocks ?? []).entities
}

export function needsRichBlocks(message: RichMessage, options: { ignoreParagraphDirection?: boolean } = {}): boolean {
  if (isExplicitDirection(message.direction)) {
    return true
  }

  for (const block of message.blocks ?? []) {
    if (block.block.oneofKind !== "paragraph") {
      return true
    }
    if (!options.ignoreParagraphDirection && isExplicitDirection(block.direction)) {
      return true
    }
    if (richTextNeedsBlocks(block.block.paragraph.text)) {
      return true
    }
  }

  return false
}

export function richMediaDependencies(message: RichMessage): MediaDependency[] {
  const deps: MediaDependency[] = []
  collectMediaDependencies(message.blocks ?? [], [], deps)
  return deps
}

function pushRichBlock(blocks: RichBlock[], block: RichBlock): void {
  if (blocks.length >= richTextLimits.maxBlocks) {
    throw new RichTextValidationError(`Rich message block count exceeds ${richTextLimits.maxBlocks}`)
  }
  blocks.push(block)
}

function assertBlockCount(items: readonly unknown[], label: string): void {
  if (items.length > richTextLimits.maxBlocks) {
    throw new RichTextValidationError(`${label} exceeds ${richTextLimits.maxBlocks}`)
  }
}

function parseDetails(lines: string[], start: number): { block: RichBlock; nextIndex: number } | undefined {
  if (!/^<details(?:\s+open)?\s*>/i.test(lines[start]?.trim() ?? "")) {
    return undefined
  }

  const body: string[] = []
  let index = start + 1
  let open = /\sopen\s*>/i.test(lines[start] ?? "")
  let summary = "Details"

  while (index < lines.length) {
    const line = lines[index] ?? ""
    if (/^<\/details\s*>/i.test(line.trim())) {
      index += 1
      break
    }

    const summaryMatch = line.trim().match(/^<summary\s*>(.*)<\/summary\s*>$/i)
    if (summaryMatch) {
      summary = stripInlineTags(summaryMatch[1] ?? "").trim() || summary
      index += 1
      continue
    }

    body.push(line)
    index += 1
  }

  const nested = parseRichMarkdown(body.join("\n")).blocks
  return {
    block: {
      blockId: "",
      direction: inferDirection(`${summary}\n${body.join("\n")}`),
      block: {
        oneofKind: "details",
        details: {
          title: parseInline(summary),
          blocks: nested,
          initiallyOpen: open,
        },
      },
    },
    nextIndex: index,
  }
}

function parseExpandableBlockquote(lines: string[], start: number): { block: RichBlock; nextIndex: number } | undefined {
  if (!/^<blockquote\s+expandable\s*>/i.test(lines[start]?.trim() ?? "")) {
    return undefined
  }

  const body: string[] = []
  let index = start + 1
  while (index < lines.length) {
    const line = lines[index] ?? ""
    if (/^<\/blockquote\s*>/i.test(line.trim())) {
      index += 1
      break
    }
    body.push(line)
    index += 1
  }

  const nested = parseRichMarkdown(body.join("\n")).blocks
  return {
    block: {
      blockId: "",
      direction: inferDirection(body.join("\n")),
      block: {
        oneofKind: "quote",
        quote: {
          blocks: nested,
          expandable: true,
          initiallyCollapsed: true,
        },
      },
    },
    nextIndex: index,
  }
}

function parseTable(lines: string[], start: number): { block: RichBlock; nextIndex: number } | undefined {
  const header = lines[start] ?? ""
  const delimiter = lines[start + 1] ?? ""
  if (!header.includes("|") || !tableDelimiterPattern.test(delimiter)) {
    return undefined
  }

  const alignments = splitTableRow(delimiter).map(parseTableAlign)
  const rows: RichTableRow[] = [
    {
      cells: splitTableRow(header).slice(0, richTextLimits.maxTableColumns).map((cell, index) =>
        tableCell(cell, {
          header: true,
          align: alignments[index],
        }),
      ),
    },
  ]

  let index = start + 2
  while (index < lines.length && rows.length < richTextLimits.maxTableRows) {
    const line = lines[index] ?? ""
    if (!line.includes("|") || isBlank(line) || startsBlock(line)) {
      break
    }
    rows.push({
      cells: splitTableRow(line).slice(0, richTextLimits.maxTableColumns).map((cell, cellIndex) =>
        tableCell(cell, {
          header: false,
          align: alignments[cellIndex],
        }),
      ),
    })
    index += 1
  }

  return {
    block: {
      blockId: "",
      direction: RichDirection.DIRECTION_AUTO,
      block: {
        oneofKind: "table",
        table: {
          rows,
          caption: [],
          bordered: false,
          striped: false,
        },
      },
    },
    nextIndex: index,
  }
}

function parseDisplayMath(lines: string[], start: number): { block: RichBlock; nextIndex: number } | undefined {
  const line = lines[start]?.trim() ?? ""
  if (!line.startsWith("$$")) {
    return undefined
  }

  if (line.length > 4 && line.endsWith("$$")) {
    return {
      block: mathBlock(line.slice(2, -2).trim(), true),
      nextIndex: start + 1,
    }
  }

  const body: string[] = []
  let index = start + 1
  while (index < lines.length) {
    const current = lines[index] ?? ""
    if (current.trim() === "$$") {
      index += 1
      break
    }
    body.push(current)
    index += 1
  }

  return {
    block: mathBlock(body.join("\n").trim(), true),
    nextIndex: index,
  }
}

function parseImageBlock(line: string): RichBlock | undefined {
  const image = parseImageOnly(line.trim())
  if (!image) {
    return undefined
  }

  const alt = unescapeMarkdownText(image.alt).trim()
  const url = normalizePublicMediaUrl(image.url)
  if (!url) {
    return undefined
  }

  return {
    blockId: "",
    direction: RichDirection.DIRECTION_AUTO,
    block: {
      oneofKind: "photo",
      photo: {
        media: {
          alt,
          fileName: undefined,
          width: undefined,
          height: undefined,
          mimeType: undefined,
          media: { oneofKind: "publicUrl", publicUrl: url },
        },
        caption: alt ? parseInline(alt) : [],
      },
    },
  }
}

function parseImageOnly(line: string): { alt: string; url: string } | undefined {
  if (!line.startsWith("![")) {
    return undefined
  }

  const labelEnd = findMarkdownClosingBracket(line, 2)
  if (labelEnd === undefined || line[labelEnd + 1] !== "(") {
    return undefined
  }

  const destination = parseMarkdownDestination(line, labelEnd + 1)
  if (!destination || line.slice(destination.end).trim()) {
    return undefined
  }

  return {
    alt: line.slice(2, labelEnd),
    url: markdownDestinationUrl(destination.value),
  }
}

function findMarkdownClosingBracket(line: string, start: number): number | undefined {
  for (let index = start; index < line.length; index += 1) {
    const char = line[index]
    if (char === "\\") {
      index += 1
      continue
    }
    if (char === "]") {
      return index
    }
  }
  return undefined
}

function parseMarkdownDestination(line: string, openParen: number): { value: string; end: number } | undefined {
  let index = openParen + 1
  while (line[index] === " " || line[index] === "\t") {
    index += 1
  }

  let depth = 0
  for (; index < line.length; index += 1) {
    const char = line[index]
    if (char === "\\") {
      index += 1
      continue
    }
    if (char === "(") {
      depth += 1
      continue
    }
    if (char !== ")") {
      continue
    }
    if (depth > 0) {
      depth -= 1
      continue
    }

    return {
      value: line.slice(openParen + 1, index).trim(),
      end: index + 1,
    }
  }

  return undefined
}

function markdownDestinationUrl(value: string): string {
  const trimmed = value.trim()
  if (trimmed.startsWith("<")) {
    const close = trimmed.indexOf(">")
    if (close !== -1) {
      return trimmed.slice(1, close).replace(/[ \t]*\n[ \t]*/g, "").trim()
    }
  }

  const title = splitMarkdownDestinationTitle(trimmed)
  return (title?.target ?? trimmed).replace(/[ \t]*\n[ \t]*/g, "").trim()
}

function splitMarkdownDestinationTitle(value: string): { target: string; title: string } | undefined {
  const end = value.trimEnd()
  const quote = end.at(-1)
  if (quote !== "\"" && quote !== "'") {
    return undefined
  }

  for (let index = end.length - 2; index >= 0; index -= 1) {
    if (end[index] !== quote) {
      continue
    }

    const beforeQuote = end[index - 1]
    if (beforeQuote === undefined || /\s/.test(beforeQuote)) {
      return {
        target: end.slice(0, index).trimEnd(),
        title: end.slice(index),
      }
    }
  }

  return undefined
}

function parseFence(lines: string[], start: number, opening: RegExpMatchArray): { block: RichBlock; nextIndex: number } {
  const fence = opening[2] ?? "```"
  const language = normalizeLanguage(opening[3] ?? "")
  const code: string[] = []
  let index = start + 1

  while (index < lines.length) {
    const line = lines[index] ?? ""
    if (line.trimStart().startsWith(fence)) {
      index += 1
      break
    }
    code.push(line)
    index += 1
  }

  return {
    block: codeBlock(code.join("\n"), language),
    nextIndex: index,
  }
}

function parseQuote(lines: string[], start: number): { block: RichBlock; nextIndex: number } {
  const quote: string[] = []
  let index = start

  while (index < lines.length) {
    const line = lines[index] ?? ""
    if (!line.trimStart().startsWith(">")) {
      break
    }
    quote.push(line.replace(/^[ \t]*>[ \t]?/, ""))
    index += 1
  }

  const text = quote.join("\n").trim()
  return {
    block: {
      blockId: "",
      direction: inferDirection(text),
      block: {
        oneofKind: "quote",
        quote: {
          blocks: text ? [paragraphBlock(text)] : [],
          expandable: false,
          initiallyCollapsed: false,
        },
      },
    },
    nextIndex: index,
  }
}

function parseList(lines: string[], start: number): { block: RichBlock; nextIndex: number } {
  const first = lines[start] ?? ""
  const firstOrdered = orderedListPattern.exec(first)
  const ordered = firstOrdered !== null
  const startNumber = firstOrdered ? Number(firstOrdered[2]) : 1
  const items: RichListItemBlock[] = []
  let index = start

  while (index < lines.length) {
    const line = lines[index] ?? ""
    const match = ordered ? orderedListPattern.exec(line) : unorderedListPattern.exec(line)
    if (!match) {
      break
    }
    if (items.length >= richTextLimits.maxBlocks) {
      throw new RichTextValidationError(`Rich message list item count exceeds ${richTextLimits.maxBlocks}`)
    }

    const item = parseListItem(match[3]?.trim() ?? "")
    items.push({
      blocks: item.text ? [paragraphBlock(item.text)] : [],
      ...(item.checked !== undefined ? { checked: item.checked } : {}),
    })
    index += 1
  }

  return {
    block: {
      blockId: "",
      direction: RichDirection.DIRECTION_AUTO,
      block: {
        oneofKind: "list",
        list: {
          ordered,
          start: ordered && Number.isFinite(startNumber) ? startNumber : 1,
          items,
        },
      },
    },
    nextIndex: index,
  }
}

function parseListItem(text: string): { text: string; checked?: boolean } {
  const task = text.match(taskListMarkerPattern)
  if (!task) {
    return { text }
  }

  return {
    text: (task[2] ?? "").trim(),
    checked: (task[1] ?? "").toLowerCase() === "x",
  }
}

function parseParagraph(lines: string[], start: number): { block: RichBlock; nextIndex: number } {
  const paragraph: string[] = []
  let index = start

  while (index < lines.length) {
    const line = lines[index] ?? ""
    if (isBlank(line) || startsBlock(line)) {
      break
    }
    paragraph.push(line.trimEnd())
    index += 1
  }

  return {
    block: paragraphBlock(paragraph.join("\n").trim()),
    nextIndex: index,
  }
}

function startsBlock(line: string): boolean {
  return Boolean(
    line.match(fencePattern) ||
      line.match(headingPattern) ||
      line.trimStart().startsWith(">") ||
      line.trimStart().startsWith("<details") ||
      line.trimStart().startsWith("<blockquote") ||
      line.trimStart().startsWith("$$") ||
      line.match(unorderedListPattern) ||
      line.match(orderedListPattern) ||
      dividerPattern.test(line),
  )
}

function paragraphBlock(text: string): RichBlock {
  return {
    blockId: "",
    direction: inferDirection(text),
    block: {
      oneofKind: "paragraph",
      paragraph: { text: parseInline(text) },
    },
  }
}

function headingBlock(text: string, level: number): RichBlock {
  return {
    blockId: "",
    direction: inferDirection(text),
    block: {
      oneofKind: "heading",
      heading: {
        text: parseInline(text),
        level: normalizeHeadingLevel(level),
      },
    },
  }
}

function codeBlock(text: string, language?: string): RichBlock {
  return {
    blockId: "",
    direction: RichDirection.DIRECTION_LTR,
    block: {
      oneofKind: "code",
      code: {
        text,
        language,
      },
    },
  }
}

function dividerBlock(): RichBlock {
  return {
    blockId: "",
    direction: RichDirection.DIRECTION_AUTO,
    block: {
      oneofKind: "divider",
      divider: {},
    },
  }
}

function mathBlock(source: string, display: boolean): RichBlock {
  return {
    blockId: "",
    direction: RichDirection.DIRECTION_LTR,
    block: {
      oneofKind: "math",
      math: {
        source,
        display,
        fallback: source,
      },
    },
  }
}

function parseInline(input: string, options: InlineParseOptions = {}): RichText[] {
  const styles = options.styles ?? []
  const depth = options.depth ?? 0
  if (!input || depth > 8) {
    return input ? [styledText(input, styles)] : []
  }

  const nodes: RichText[] = []
  let buffer = ""
  let index = 0

  const flush = () => {
    if (!buffer) return
    nodes.push(styledText(buffer, styles))
    buffer = ""
  }

  while (index < input.length) {
    const char = input[index]

    if (char === "\\" && index + 1 < input.length) {
      buffer += input[index + 1]
      index += 2
      continue
    }

    const code = readDelimited(input, index, "`", "`")
    if (code) {
      flush()
      nodes.push(styledText(code.content, addStyle(styles, RichTextStyle.STYLE_CODE)))
      index = code.end
      continue
    }

    const link = readMarkdownLink(input, index)
    if (link) {
      flush()
      const children = parseInline(link.label, { styles, depth: depth + 1 })
      nodes.push(...children.map((node) => applyUrl(node, link.url)))
      index = link.end
      continue
    }

    const underline = readHtmlTag(input, index, "u")
    if (underline) {
      flush()
      nodes.push(...parseInline(underline.content, {
        styles: addStyle(styles, RichTextStyle.STYLE_UNDERLINE),
        depth: depth + 1,
      }))
      index = underline.end
      continue
    }

    const spoiler = readDelimited(input, index, "||", "||")
    if (spoiler) {
      flush()
      nodes.push(...parseInline(spoiler.content, {
        styles: addStyle(styles, RichTextStyle.STYLE_SPOILER),
        depth: depth + 1,
      }))
      index = spoiler.end
      continue
    }

    const strong = readDelimited(input, index, "**", "**") ?? readDelimited(input, index, "__", "__")
    if (strong) {
      flush()
      nodes.push(...parseInline(strong.content, {
        styles: addStyle(styles, RichTextStyle.STYLE_BOLD),
        depth: depth + 1,
      }))
      index = strong.end
      continue
    }

    const strike = readDelimited(input, index, "~~", "~~")
    if (strike) {
      flush()
      nodes.push(...parseInline(strike.content, {
        styles: addStyle(styles, RichTextStyle.STYLE_STRIKETHROUGH),
        depth: depth + 1,
      }))
      index = strike.end
      continue
    }

    const italic = readDelimited(input, index, "*", "*") ?? readDelimited(input, index, "_", "_")
    if (italic) {
      flush()
      nodes.push(...parseInline(italic.content, {
        styles: addStyle(styles, RichTextStyle.STYLE_ITALIC),
        depth: depth + 1,
      }))
      index = italic.end
      continue
    }

    buffer += char
    index += 1
  }

  flush()
  return compactRichText(nodes)
}

function readDelimited(
  input: string,
  index: number,
  open: string,
  close: string,
): { content: string; end: number } | undefined {
  if (!input.startsWith(open, index)) {
    return undefined
  }

  const contentStart = index + open.length
  const closeIndex = input.indexOf(close, contentStart)
  if (closeIndex <= contentStart) {
    return undefined
  }

  return {
    content: input.slice(contentStart, closeIndex),
    end: closeIndex + close.length,
  }
}

function readHtmlTag(input: string, index: number, tag: string): { content: string; end: number } | undefined {
  const open = `<${tag}>`
  const close = `</${tag}>`
  if (!input.toLowerCase().startsWith(open, index)) {
    return undefined
  }

  const closeIndex = input.toLowerCase().indexOf(close, index + open.length)
  if (closeIndex <= index + open.length) {
    return undefined
  }

  return {
    content: input.slice(index + open.length, closeIndex),
    end: closeIndex + close.length,
  }
}

function readMarkdownLink(input: string, index: number): { label: string; url: string; end: number } | undefined {
  if (input[index] !== "[") {
    return undefined
  }

  const labelEnd = findMatching(input, index, "[", "]")
  if (labelEnd === -1 || input[labelEnd + 1] !== "(") {
    return undefined
  }

  const urlEnd = findMatching(input, labelEnd + 1, "(", ")")
  if (urlEnd === -1) {
    return undefined
  }

  const rawUrl = input.slice(labelEnd + 2, urlEnd).trim()
  const url = normalizeUrl(rawUrl)
  if (!url) {
    return undefined
  }

  return {
    label: input.slice(index + 1, labelEnd),
    url,
    end: urlEnd + 1,
  }
}

function findMatching(input: string, start: number, open: string, close: string): number {
  let depth = 0
  for (let i = start; i < input.length; i++) {
    if (input[i] === "\\") {
      i += 1
      continue
    }
    if (input[i] === open) {
      depth += 1
    } else if (input[i] === close) {
      depth -= 1
      if (depth === 0) {
        return i
      }
    }
  }
  return -1
}

function normalizeBlocks(
  blocks: RichBlock[],
  ctx: NormalizeBlockContext,
): RichBlock[] {
  if (ctx.depth > richTextLimits.maxDepth) {
    throw new RichTextValidationError(`Rich message depth exceeds ${richTextLimits.maxDepth}`)
  }
  assertBlockCount(blocks, "Rich message block count")

  const normalized: RichBlock[] = []
  for (const [index, block] of blocks.entries()) {
    const path = [...ctx.path, index]
    const normalizedBlock = normalizeBlock(block, {
      depth: ctx.depth,
      path,
      allowThinking: ctx.allowThinking,
      blockBudget: ctx.blockBudget,
    })
    if (normalizedBlock) {
      ctx.blockBudget.count += 1
      if (ctx.blockBudget.count > richTextLimits.maxBlocks) {
        throw new RichTextValidationError(`Rich message block count exceeds ${richTextLimits.maxBlocks}`)
      }
      if (normalized.length >= richTextLimits.maxBlocks) {
        throw new RichTextValidationError(`Rich message block count exceeds ${richTextLimits.maxBlocks}`)
      }
      normalized.push(normalizedBlock)
    }
  }

  return normalized
}

function assertMediaCount(blocks: RichBlock[]): void {
  const count = countMediaRefs(blocks)
  if (count > richTextLimits.maxMedia) {
    throw new RichTextValidationError(`Rich message media count exceeds ${richTextLimits.maxMedia}`)
  }
}

function countMediaRefs(blocks: RichBlock[]): number {
  let count = 0

  const countRef = (ref: RichMediaRef | undefined) => {
    if (ref && mediaDependencyKind(ref)) {
      count += 1
    }
  }

  for (const block of blocks) {
    switch (block.block.oneofKind) {
      case "photo":
        countRef(block.block.photo.media)
        break
      case "video":
        countRef(block.block.video.media)
        break
      case "document":
        countRef(block.block.document.media)
        break
      case "audio":
        countRef(block.block.audio.media)
        break
      case "embed":
        countRef(block.block.embed.poster)
        break
      case "embedPost":
        countRef(block.block.embedPost.authorPhoto)
        count += countMediaRefs(block.block.embedPost.blocks)
        break
      case "linkPreview":
        countRef(block.block.linkPreview.media)
        break
      case "collage":
        count += countMediaRefs(block.block.collage.items)
        break
      case "list":
        for (const item of block.block.list.items) {
          count += countMediaRefs(item.blocks)
        }
        break
      case "listItem":
        count += countMediaRefs(block.block.listItem.blocks)
        break
      case "quote":
        count += countMediaRefs(block.block.quote.blocks)
        break
      case "details":
        count += countMediaRefs(block.block.details.blocks)
        break
      case "thinking":
        count += countMediaRefs(block.block.thinking.blocks)
        break
      default:
        break
    }
  }

  return count
}

function normalizeBlock(
  block: RichBlock,
  ctx: NormalizeBlockContext,
): RichBlock | undefined {
  if (block.block.oneofKind === undefined) {
    return undefined
  }
  if (block.block.oneofKind === "thinking" && !ctx.allowThinking) {
    return undefined
  }

  const direction = normalizeDirection(block.direction) ?? inferDirection(renderBlockFallback(block))
  const normalized: RichBlock = {
    blockId: normalizeBlockId(block.blockId) || generatedBlockId(block, ctx.path),
    direction,
    block: normalizeBlockPayload(block, {
      depth: ctx.depth + 1,
      path: ctx.path,
      allowThinking: ctx.allowThinking,
      blockBudget: ctx.blockBudget,
    }),
  }

  return normalized.block.oneofKind === undefined ? undefined : normalized
}

function normalizeBlockPayload(
  block: RichBlock,
  ctx: NormalizeBlockContext,
): RichBlock["block"] {
  switch (block.block.oneofKind) {
    case "paragraph":
      return {
        oneofKind: "paragraph",
        paragraph: { text: normalizeRichTextList(block.block.paragraph.text ?? [], ctx.depth) },
      }
    case "heading":
      return {
        oneofKind: "heading",
        heading: {
          text: normalizeRichTextList(block.block.heading.text ?? [], ctx.depth),
          level: normalizeHeadingLevel(block.block.heading.level),
        },
      }
    case "list":
      assertBlockCount(block.block.list.items ?? [], "Rich message list item count")
      return {
        oneofKind: "list",
        list: {
          ordered: Boolean(block.block.list.ordered),
          start: block.block.list.ordered ? normalizeStart(block.block.list.start) : 1,
          items: (block.block.list.items ?? []).map((item, itemIndex) => ({
            blocks: normalizeBlocks(item.blocks ?? [], {
              depth: ctx.depth,
              path: [...ctx.path, itemIndex],
              allowThinking: ctx.allowThinking,
              blockBudget: ctx.blockBudget,
            }),
            ...(item.checked !== undefined ? { checked: Boolean(item.checked) } : {}),
          })),
        },
      }
    case "listItem":
      return {
        oneofKind: "listItem",
        listItem: {
          blocks: normalizeBlocks(block.block.listItem.blocks ?? [], ctx),
          ...(block.block.listItem.checked !== undefined ? { checked: Boolean(block.block.listItem.checked) } : {}),
        },
      }
    case "quote":
      return {
        oneofKind: "quote",
        quote: {
          blocks: normalizeBlocks(block.block.quote.blocks ?? [], ctx),
          expandable: Boolean(block.block.quote.expandable),
          initiallyCollapsed: Boolean(block.block.quote.initiallyCollapsed),
        },
      }
    case "code":
      return {
        oneofKind: "code",
        code: {
          text: normalizeInputText(block.block.code.text ?? ""),
          language: normalizeLanguage(block.block.code.language ?? ""),
        },
      }
    case "divider":
      return { oneofKind: "divider", divider: {} }
    case "thinking":
      return {
        oneofKind: "thinking",
        thinking: {
          blocks: normalizeBlocks(block.block.thinking.blocks ?? [], ctx),
          initiallyCollapsed: block.block.thinking.initiallyCollapsed,
        },
      }
    case "details":
      return {
        oneofKind: "details",
        details: {
          title: normalizeRichTextList(block.block.details.title ?? [], ctx.depth),
          blocks: normalizeBlocks(block.block.details.blocks ?? [], ctx),
          initiallyOpen: Boolean(block.block.details.initiallyOpen),
        },
      }
    case "photo":
      return {
        oneofKind: "photo",
        photo: {
          media: normalizeMediaRef(block.block.photo.media),
          caption: normalizeRichTextList(block.block.photo.caption ?? [], ctx.depth),
        },
      }
    case "video":
      return {
        oneofKind: "video",
        video: {
          media: normalizeMediaRef(block.block.video.media),
          caption: normalizeRichTextList(block.block.video.caption ?? [], ctx.depth),
          duration: normalizePositiveInt(block.block.video.duration),
        },
      }
    case "document":
      return {
        oneofKind: "document",
        document: {
          media: normalizeMediaRef(block.block.document.media),
          caption: normalizeRichTextList(block.block.document.caption ?? [], ctx.depth),
        },
      }
    case "audio":
      return {
        oneofKind: "audio",
        audio: {
          media: normalizeMediaRef(block.block.audio.media),
          caption: normalizeRichTextList(block.block.audio.caption ?? [], ctx.depth),
          duration: normalizePositiveInt(block.block.audio.duration),
          title: normalizeOptionalText(block.block.audio.title),
          performer: normalizeOptionalText(block.block.audio.performer),
        },
      }
    case "table":
      return {
        oneofKind: "table",
        table: {
          rows: normalizeTableRows(block.block.table.rows ?? [], ctx.depth),
          caption: normalizeRichTextList(block.block.table.caption ?? [], ctx.depth),
          bordered: Boolean(block.block.table.bordered),
          striped: Boolean(block.block.table.striped),
        },
      }
    case "math":
      return {
        oneofKind: "math",
        math: {
          source: normalizeInputText(block.block.math.source ?? "").trim(),
          display: Boolean(block.block.math.display),
          fallback: normalizeOptionalText(block.block.math.fallback),
        },
      }
    case "map":
      return {
        oneofKind: "map",
        map: {
          latitude: clamp(block.block.map.latitude, -90, 90),
          longitude: clamp(block.block.map.longitude, -180, 180),
          zoom: Math.min(22, Math.max(0, Math.trunc(block.block.map.zoom || 0))),
          caption: normalizeRichTextList(block.block.map.caption ?? [], ctx.depth),
          title: normalizeOptionalText(block.block.map.title),
          address: normalizeOptionalText(block.block.map.address),
          openUrl: normalizeUrl(block.block.map.openUrl ?? ""),
          aspectRatio: clamp(block.block.map.aspectRatio || 0, 0, 4) || undefined,
        },
      }
    case "embed":
      return {
        oneofKind: "embed",
        embed: {
          url: normalizeUrl(block.block.embed.url ?? ""),
          html: normalizeOptionalText(block.block.embed.html),
          poster: block.block.embed.poster ? normalizeMediaRef(block.block.embed.poster) : undefined,
          width: normalizePositiveInt(block.block.embed.width),
          height: normalizePositiveInt(block.block.embed.height),
          caption: normalizeRichTextList(block.block.embed.caption ?? [], ctx.depth),
          fullWidth: Boolean(block.block.embed.fullWidth),
          allowScrolling: Boolean(block.block.embed.allowScrolling),
          provider: normalizeOptionalText(block.block.embed.provider),
        },
      }
    case "embedPost":
      return {
        oneofKind: "embedPost",
        embedPost: {
          url: normalizeUrl(block.block.embedPost.url ?? "") ?? "",
          author: normalizeOptionalText(block.block.embedPost.author) ?? "",
          authorPhoto: block.block.embedPost.authorPhoto ? normalizeMediaRef(block.block.embedPost.authorPhoto) : undefined,
          date: block.block.embedPost.date,
          blocks: normalizeBlocks(block.block.embedPost.blocks ?? [], ctx),
          caption: normalizeRichTextList(block.block.embedPost.caption ?? [], ctx.depth),
        },
      }
    case "linkPreview":
      return {
        oneofKind: "linkPreview",
        linkPreview: {
          url: normalizeUrl(block.block.linkPreview.url ?? "") ?? "",
          displayUrl: normalizeOptionalText(block.block.linkPreview.displayUrl),
          siteName: normalizeOptionalText(block.block.linkPreview.siteName),
          title: normalizeOptionalText(block.block.linkPreview.title),
          description: normalizeOptionalText(block.block.linkPreview.description),
          media: block.block.linkPreview.media ? normalizeMediaRef(block.block.linkPreview.media) : undefined,
          mediaAspectRatio: clamp(block.block.linkPreview.mediaAspectRatio || 0, 0, 4) || undefined,
          compact: Boolean(block.block.linkPreview.compact),
        },
      }
    case "collage":
      return {
        oneofKind: "collage",
        collage: {
          items: normalizeBlocks(block.block.collage.items ?? [], ctx),
          caption: normalizeRichTextList(block.block.collage.caption ?? [], ctx.depth),
          layout: normalizeCollageLayout(block.block.collage.layout),
        },
      }
    default:
      return { oneofKind: undefined }
  }
}

function normalizeRichTextList(nodes: RichText[], depth: number): RichText[] {
  return compactRichText((nodes ?? []).map((node) => normalizeRichText(node, depth + 1)).filter(Boolean))
}

function normalizeRichText(node: RichText, depth: number): RichText | undefined {
  if (depth > richTextLimits.maxDepth) {
    throw new RichTextValidationError(`Rich message depth exceeds ${richTextLimits.maxDepth}`)
  }

  const text = normalizeInputText(node.text ?? "")
  const children = normalizeRichTextList(node.children ?? [], depth + 1)
  const styles = uniqueStyles(node.styles ?? [])
  const url = normalizeUrl(node.url ?? "")

  if (!text && children.length === 0) {
    return undefined
  }

  return {
    text,
    children,
    styles,
    url,
  }
}

function normalizeMediaRef(ref: RichMediaRef | undefined): RichMediaRef {
  if (!ref) {
    return emptyMediaRef()
  }

  let media: RichMediaRef["media"] = { oneofKind: undefined }
  switch (ref.media.oneofKind) {
    case "photoId":
      if (ref.media.photoId > 0n) {
        media = ref.media
      }
      break
    case "videoId":
      if (ref.media.videoId > 0n) {
        media = ref.media
      }
      break
    case "documentId":
      if (ref.media.documentId > 0n) {
        media = ref.media
      }
      break
    case "voiceId":
      if (ref.media.voiceId > 0n) {
        media = ref.media
      }
      break
    case "publicUrl": {
      const publicUrl = normalizePublicMediaUrl(ref.media.publicUrl)
      if (publicUrl) {
        media = { oneofKind: "publicUrl", publicUrl }
      }
      break
    }
    default:
      break
  }

  return {
    alt: normalizeOptionalText(ref.alt) ?? "",
    fileName: normalizeOptionalText(ref.fileName),
    width: normalizePositiveInt(ref.width),
    height: normalizePositiveInt(ref.height),
    mimeType: normalizeOptionalText(ref.mimeType),
    cdnUrl: ref.cdnUrl ? normalizePublicMediaUrl(ref.cdnUrl) : undefined,
    fileUniqueId: normalizeOptionalText(ref.fileUniqueId),
    media,
  }
}

function emptyMediaRef(): RichMediaRef {
  return {
    alt: "",
    media: { oneofKind: undefined },
  }
}

function normalizeTableRows(rows: RichTableRow[], depth: number): RichTableRow[] {
  const normalizedRows = rows.slice(0, richTextLimits.maxTableRows)
  return normalizedRows.map((row, rowIndex) => ({
    cells: (row.cells ?? []).slice(0, richTextLimits.maxTableColumns).map((cell) => ({
      text: normalizeRichTextList(cell.text ?? [], depth + 1),
      header: Boolean(cell.header),
      colspan: normalizeTableSpan(cell.colspan, richTextLimits.maxTableColumns),
      rowspan: normalizeTableSpan(cell.rowspan, Math.max(1, normalizedRows.length - rowIndex)),
      align: normalizeHorizontalAlign(cell.align),
      valign: normalizeVerticalAlign(cell.valign),
    })),
  }))
}

function normalizeTableSpan(value: number | undefined, max: number): number {
  const span = Math.trunc(value ?? 1)
  if (!Number.isFinite(span)) {
    return 1
  }
  return Math.max(1, Math.min(max, span))
}

function renderRichBlocks(blocks: RichBlock[]): RenderedRichMessage {
  const ctx: RenderContext = { text: "", entities: [] }

  blocks.forEach((block, index) => {
    if (index > 0 && ctx.text.length > 0) {
      ctx.text += "\n\n"
    }
    renderBlock(block, ctx, 0, index)
  })

  return {
    text: ctx.text,
    entities: ctx.entities.length > 0 ? { entities: sortEntities(ctx.entities) } : undefined,
  }
}

function renderBlock(block: RichBlock, ctx: RenderContext, depth: number, index: number): void {
  switch (block.block.oneofKind) {
    case "heading": {
      const start = ctx.text.length
      renderInlineNodes(block.block.heading.text, ctx)
      pushEntity(ctx, MessageEntity_Type.BOLD, start, ctx.text.length - start)
      break
    }
    case "paragraph":
      renderInlineNodes(block.block.paragraph.text, ctx)
      break
    case "listItem":
      renderNestedBlocks(block.block.listItem.blocks, ctx, depth)
      break
    case "quote": {
      const start = ctx.text.length
      renderNestedBlocks(block.block.quote.blocks, ctx, depth)
      pushEntity(
        ctx,
        block.block.quote.expandable ? MessageEntity_Type.EXPANDABLE_BLOCKQUOTE : MessageEntity_Type.BLOCKQUOTE,
        start,
        ctx.text.length - start,
      )
      break
    }
    case "details": {
      renderInlineNodes(block.block.details.title, ctx)
      if (block.block.details.blocks.length > 0) {
        ctx.text += "\n"
        renderNestedBlocks(block.block.details.blocks, ctx, depth)
      }
      break
    }
    case "code": {
      const start = ctx.text.length
      ctx.text += block.block.code.text
      pushEntity(ctx, MessageEntity_Type.PRE, start, ctx.text.length - start, block.block.code.language)
      break
    }
    case "divider":
      ctx.text += "---"
      break
    case "list": {
      const ordered = block.block.list.ordered
      const listStart = block.block.list.start || 1
      block.block.list.items.forEach((item, childIndex) => {
        if (childIndex > 0) {
          ctx.text += "\n"
        }
        const taskMarker = item.checked === undefined ? "" : item.checked ? "[x] " : "[ ] "
        const prefix = ordered ? `${listStart + childIndex}. ${taskMarker}` : `- ${taskMarker}`
        ctx.text += "  ".repeat(depth) + prefix
        renderNestedBlocks(item.blocks, ctx, depth + 1)
      })
      break
    }
    case "photo":
      renderMediaFallback(ctx, "Image", block.block.photo.media ?? emptyMediaRef(), block.block.photo.caption)
      break
    case "video":
      renderMediaFallback(ctx, "Video", block.block.video.media ?? emptyMediaRef(), block.block.video.caption)
      break
    case "document":
      renderMediaFallback(ctx, "Document", block.block.document.media ?? emptyMediaRef(), block.block.document.caption)
      break
    case "audio":
      renderMediaFallback(ctx, "Audio", block.block.audio.media ?? emptyMediaRef(), block.block.audio.caption)
      break
    case "table":
      renderTable(block.block.table.rows, ctx)
      break
    case "math":
      ctx.text += block.block.math.fallback || block.block.math.source
      break
    case "map":
      ctx.text += block.block.map.title || block.block.map.address || "Map"
      if (block.block.map.caption.length > 0) {
        ctx.text += ": "
        renderInlineNodes(block.block.map.caption, ctx)
      }
      break
    case "embed":
      ctx.text += block.block.embed.provider || block.block.embed.url || "Embed"
      if (block.block.embed.caption.length > 0) {
        ctx.text += ": "
        renderInlineNodes(block.block.embed.caption, ctx)
      }
      break
    case "embedPost":
      ctx.text += block.block.embedPost.author || block.block.embedPost.url
      if (block.block.embedPost.blocks.length > 0) {
        ctx.text += "\n"
        renderNestedBlocks(block.block.embedPost.blocks, ctx, depth)
      }
      break
    case "linkPreview":
      ctx.text += block.block.linkPreview.title || block.block.linkPreview.displayUrl || block.block.linkPreview.url
      break
    case "collage":
      ctx.text += `Collage (${block.block.collage.items.length})`
      if (block.block.collage.caption.length > 0) {
        ctx.text += ": "
        renderInlineNodes(block.block.collage.caption, ctx)
      }
      break
    case "thinking":
    case undefined:
      break
    default:
      if (index > -1) {
        ctx.text += renderBlockFallback(block)
      }
      break
  }
}

function renderNestedBlocks(blocks: RichBlock[], ctx: RenderContext, depth: number): void {
  blocks.forEach((block, index) => {
    if (index > 0) {
      ctx.text += "\n"
    }
    renderBlock(block, ctx, depth, index)
  })
}

function renderMediaFallback(ctx: RenderContext, label: string, media: RichMediaRef, caption: RichText[]): void {
  const alt = media.alt?.trim()
  ctx.text += alt ? `[${label}: ${alt}]` : `[${label}]`
  if (caption.length > 0) {
    ctx.text += " "
    renderInlineNodes(caption, ctx)
  }
}

function renderTable(rows: RichTableRow[], ctx: RenderContext): void {
  rows.forEach((row, rowIndex) => {
    if (rowIndex > 0) {
      ctx.text += "\n"
    }
    const cells = row.cells.map((cell) => flattenRichText(cell.text).replace(/\s+/g, " ").trim())
    ctx.text += cells.join(" | ")
  })
}

function renderInlineNodes(nodes: RichText[], ctx: RenderContext): void {
  for (const node of nodes) {
    renderInlineNode(node, ctx)
  }
}

function renderInlineNode(node: RichText, ctx: RenderContext): void {
  const start = ctx.text.length

  if (node.text) {
    ctx.text += node.text
  }
  if (node.children?.length) {
    renderInlineNodes(node.children, ctx)
  }

  const length = ctx.text.length - start
  if (length <= 0) {
    return
  }

  for (const style of node.styles ?? []) {
    const type = entityTypeForStyle(style)
    if (type) {
      pushEntity(ctx, type, start, length)
    }
  }

  if (node.url) {
    pushEntity(ctx, MessageEntity_Type.TEXT_URL, start, length, undefined, node.url)
  }
}

function pushEntity(
  ctx: RenderContext,
  type: MessageEntity_Type,
  start: number,
  length: number,
  language?: string,
  url?: string,
): void {
  if (length <= 0) {
    return
  }

  const entity: MessageEntity = {
    type,
    offset: BigInt(start),
    length: BigInt(length),
    entity: { oneofKind: undefined },
  }

  if (type === MessageEntity_Type.PRE) {
    entity.entity = { oneofKind: "pre", pre: { language: language ?? "" } }
  } else if (type === MessageEntity_Type.TEXT_URL && url) {
    entity.entity = { oneofKind: "textUrl", textUrl: { url } }
  }

  ctx.entities.push(entity)
}

function entityTypeForStyle(style: RichTextStyle): MessageEntity_Type | undefined {
  switch (style) {
    case RichTextStyle.STYLE_BOLD:
      return MessageEntity_Type.BOLD
    case RichTextStyle.STYLE_ITALIC:
      return MessageEntity_Type.ITALIC
    case RichTextStyle.STYLE_UNDERLINE:
      return MessageEntity_Type.UNDERLINE
    case RichTextStyle.STYLE_STRIKETHROUGH:
      return MessageEntity_Type.STRIKETHROUGH
    case RichTextStyle.STYLE_CODE:
      return MessageEntity_Type.CODE
    default:
      return undefined
  }
}

function richTextNeedsBlocks(nodes: RichText[]): boolean {
  for (const node of nodes) {
    for (const style of node.styles ?? []) {
      if (!isFlatEntityStyle(style)) {
        return true
      }
    }
    if (richTextNeedsBlocks(node.children ?? [])) {
      return true
    }
  }

  return false
}

function isFlatEntityStyle(style: RichTextStyle): boolean {
  switch (style) {
    case RichTextStyle.STYLE_UNSPECIFIED:
    case RichTextStyle.STYLE_BOLD:
    case RichTextStyle.STYLE_ITALIC:
    case RichTextStyle.STYLE_UNDERLINE:
    case RichTextStyle.STYLE_STRIKETHROUGH:
    case RichTextStyle.STYLE_CODE:
      return true
    default:
      return false
  }
}

function isExplicitDirection(direction: RichDirection | undefined): boolean {
  return direction !== undefined && direction !== RichDirection.DIRECTION_UNSPECIFIED && direction !== RichDirection.DIRECTION_AUTO
}

function collectMediaDependencies(blocks: RichBlock[], path: number[], deps: MediaDependency[]): void {
  blocks.forEach((block, index) => {
    const blockPath = [...path, index]
    const pushRef = (ref: RichMediaRef, defaultKind: MediaDependency["kind"]) => {
      const kind = mediaDependencyKind(ref) ?? defaultKind
      deps.push({
        blockId: block.blockId,
        blockPath: blockPath.join("."),
        sortOrder: deps.length,
        kind,
        ref,
      })
    }

    switch (block.block.oneofKind) {
      case "photo":
        if (block.block.photo.media) pushRef(block.block.photo.media, "photo")
        break
      case "video":
        if (block.block.video.media) pushRef(block.block.video.media, "video")
        break
      case "document":
        if (block.block.document.media) pushRef(block.block.document.media, "document")
        break
      case "audio":
        if (block.block.audio.media) pushRef(block.block.audio.media, "voice")
        break
      case "embed":
        if (block.block.embed.poster) pushRef(block.block.embed.poster, "photo")
        break
      case "embedPost":
        if (block.block.embedPost.authorPhoto) pushRef(block.block.embedPost.authorPhoto, "photo")
        collectMediaDependencies(block.block.embedPost.blocks, blockPath, deps)
        break
      case "linkPreview":
        if (block.block.linkPreview.media) pushRef(block.block.linkPreview.media, "photo")
        break
      case "collage":
        collectMediaDependencies(block.block.collage.items, blockPath, deps)
        break
      case "list":
        block.block.list.items.forEach((item, itemIndex) => collectMediaDependencies(item.blocks, [...blockPath, itemIndex], deps))
        break
      case "listItem":
        collectMediaDependencies(block.block.listItem.blocks, blockPath, deps)
        break
      case "quote":
        collectMediaDependencies(block.block.quote.blocks, blockPath, deps)
        break
      case "details":
        collectMediaDependencies(block.block.details.blocks, blockPath, deps)
        break
      case "thinking":
        collectMediaDependencies(block.block.thinking.blocks, blockPath, deps)
        break
      default:
        break
    }
  })
}

function mediaDependencyKind(ref: RichMediaRef): MediaDependency["kind"] | undefined {
  switch (ref.media.oneofKind) {
    case "photoId":
      return "photo"
    case "videoId":
      return "video"
    case "documentId":
      return "document"
    case "voiceId":
      return "voice"
    case "publicUrl":
      return "public_url"
    default:
      return undefined
  }
}

function renderBlockFallback(block: RichBlock): string {
  const rendered = renderRichBlocks([block])
  return rendered.text
}

function generatedBlockId(block: RichBlock, path: number[]): string {
  const kind = block.block.oneofKind ?? "unknown"
  const content = renderBlockFallback({ ...block, blockId: "" })
  return `b_${path.join("_")}_${kind}_${hashString(`${kind}:${content}`).slice(0, 10)}`
}

function normalizeBlockId(value: string): string | undefined {
  const id = value.trim().replace(/[^\w:-]/g, "_").slice(0, 80)
  return id || undefined
}

function tableCell(
  raw: string,
  options: { header: boolean; align?: RichHorizontalAlign },
): RichTableCell {
  return {
    text: parseInline(raw.trim()),
    header: options.header,
    colspan: 1,
    rowspan: 1,
    align: options.align,
    valign: RichVerticalAlign.VERTICAL_ALIGN_UNSPECIFIED,
  }
}

function parseTableAlign(raw: string): RichHorizontalAlign {
  const value = raw.trim()
  const left = value.startsWith(":")
  const right = value.endsWith(":")
  if (left && right) return RichHorizontalAlign.HORIZONTAL_ALIGN_CENTER
  if (right) return RichHorizontalAlign.HORIZONTAL_ALIGN_RIGHT
  if (left) return RichHorizontalAlign.HORIZONTAL_ALIGN_LEFT
  return RichHorizontalAlign.HORIZONTAL_ALIGN_UNSPECIFIED
}

function splitTableRow(raw: string): string[] {
  let value = raw.trim()
  if (value.startsWith("|")) value = value.slice(1)
  if (value.endsWith("|")) value = value.slice(0, -1)
  return value.split("|").map((cell) => cell.trim())
}

function normalizeDirection(direction: RichDirection | undefined): RichDirection | undefined {
  switch (direction) {
    case RichDirection.DIRECTION_AUTO:
    case RichDirection.DIRECTION_LTR:
    case RichDirection.DIRECTION_RTL:
      return direction
    default:
      return undefined
  }
}

function normalizeHeadingLevel(level: number | undefined): number {
  if (!level || !Number.isFinite(level)) {
    return 1
  }
  return Math.min(6, Math.max(1, Math.trunc(level)))
}

function normalizeStart(value: number | undefined): number {
  if (!value || !Number.isFinite(value)) {
    return 1
  }
  return Math.max(1, Math.trunc(value))
}

function normalizePositiveInt(value: number | undefined): number | undefined {
  if (!value || !Number.isFinite(value)) {
    return undefined
  }
  return Math.max(1, Math.trunc(value))
}

function normalizeLanguage(value: string): string | undefined {
  const language = value.trim().replace(/[^\w.+-]/g, "").slice(0, richTextLimits.maxLanguageLength)
  return language || undefined
}

function normalizeOptionalText(value: string | undefined): string | undefined {
  const text = normalizeInputText(value ?? "").trim()
  return text || undefined
}

function normalizeHorizontalAlign(value: RichHorizontalAlign | undefined): RichHorizontalAlign | undefined {
  switch (value) {
    case RichHorizontalAlign.HORIZONTAL_ALIGN_LEFT:
    case RichHorizontalAlign.HORIZONTAL_ALIGN_CENTER:
    case RichHorizontalAlign.HORIZONTAL_ALIGN_RIGHT:
      return value
    default:
      return undefined
  }
}

function normalizeVerticalAlign(value: RichVerticalAlign | undefined): RichVerticalAlign | undefined {
  switch (value) {
    case RichVerticalAlign.VERTICAL_ALIGN_TOP:
    case RichVerticalAlign.VERTICAL_ALIGN_MIDDLE:
    case RichVerticalAlign.VERTICAL_ALIGN_BOTTOM:
      return value
    default:
      return undefined
  }
}

function normalizeCollageLayout(value: RichCollageLayout | undefined): RichCollageLayout | undefined {
  switch (value) {
    case RichCollageLayout.COLLAGE_LAYOUT_GRID:
    case RichCollageLayout.COLLAGE_LAYOUT_MASONRY:
      return value
    default:
      return undefined
  }
}

function normalizeUrl(raw: string, options: { allowPublicUrl?: boolean } = {}): string | undefined {
  let value = raw.trim()
  if (!value) {
    return undefined
  }
  if (value.startsWith("<") && value.endsWith(">")) {
    value = value.slice(1, -1).trim()
  }
  if (!value || value.length > richTextLimits.maxUrlLength) {
    return undefined
  }

  try {
    const url = new URL(value)
    const protocol = url.protocol.toLowerCase()
    if (protocol === "http:" || protocol === "https:") {
      return options.allowPublicUrl || protocol === "https:" ? value : undefined
    }
    if (protocol === "mailto:" || protocol === "tel:" || protocol === "inline:") {
      return value
    }
  } catch {
    return undefined
  }

  return undefined
}

function normalizePublicMediaUrl(raw: string): string | undefined {
  const value = normalizeUrl(raw, { allowPublicUrl: true })
  if (!value) {
    return undefined
  }

  try {
    const url = new URL(value)
    if (url.protocol !== "https:" || url.username || url.password) {
      return undefined
    }
    return url.toString()
  } catch {
    return undefined
  }
}

function inferDirection(text: string): RichDirection | undefined {
  for (const char of text) {
    if (rtlPattern.test(char)) {
      return RichDirection.DIRECTION_RTL
    }
    if (ltrPattern.test(char)) {
      return RichDirection.DIRECTION_LTR
    }
  }
  return undefined
}

function styledText(text: string, styles: RichTextStyle[]): RichText {
  return {
    text,
    children: [],
    styles: uniqueStyles(styles),
  }
}

function applyUrl(node: RichText, url: string): RichText {
  return {
    ...node,
    url,
    children: node.children?.map((child) => applyUrl(child, url)) ?? [],
  }
}

function addStyle(styles: RichTextStyle[], style: RichTextStyle): RichTextStyle[] {
  return styles.includes(style) ? styles : [...styles, style]
}

function uniqueStyles(styles: RichTextStyle[]): RichTextStyle[] {
  return [...new Set(styles.filter((style) => style !== RichTextStyle.STYLE_UNSPECIFIED))]
}

function compactRichText(nodes: Array<RichText | undefined>): RichText[] {
  const output: RichText[] = []
  for (const node of nodes) {
    if (!node) {
      continue
    }

    const previous = output.at(-1)
    if (
      previous &&
      !previous.url &&
      !node.url &&
      previous.children.length === 0 &&
      node.children.length === 0 &&
      sameStyles(previous.styles, node.styles)
    ) {
      previous.text += node.text
    } else {
      output.push(node)
    }
  }
  return output
}

function sameStyles(a: RichTextStyle[], b: RichTextStyle[]): boolean {
  if (a.length !== b.length) {
    return false
  }
  return a.every((style, index) => style === b[index])
}

function flattenRichText(nodes: RichText[]): string {
  let text = ""
  for (const node of nodes) {
    text += node.text
    text += flattenRichText(node.children ?? [])
  }
  return text
}

function sortEntities(entities: MessageEntity[]): MessageEntity[] {
  return entities.sort((a, b) => {
    if (a.offset === b.offset) {
      if (a.length === b.length) {
        return 0
      }
      return a.length < b.length ? -1 : 1
    }
    return a.offset < b.offset ? -1 : 1
  })
}

function normalizeInputText(text: string): string {
  return text.replace(/\r\n?/g, "\n")
}

function stripInlineTags(text: string): string {
  return text.replace(/<\/?[^>]+>/g, "")
}

function unescapeMarkdownText(text: string): string {
  return text.replace(/\\([\\[\]()`*_{}.!#+\->|])/g, "$1")
}

function assertTextLength(text: string): void {
  if (text.length > richTextLimits.maxTextLength) {
    throw new RichTextValidationError("rich text exceeds maximum text length")
  }
}

function isBlank(line: string): boolean {
  return line.trim().length === 0
}

function clamp(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) {
    return 0
  }
  return Math.min(max, Math.max(min, value))
}

function hashString(value: string): string {
  let hash = 0x811c9dc5
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index)
    hash = Math.imul(hash, 0x01000193) >>> 0
  }
  return hash.toString(16).padStart(8, "0")
}
