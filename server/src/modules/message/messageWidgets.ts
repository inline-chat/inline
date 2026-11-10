import {
  AgentGrantRequirement,
  type Block,
  type BlockContent,
  type BlockImage,
  type BlockText,
  type BlockWidget,
  type MessageWidgetCall,
} from "@inline-chat/protocol/core"
import { isClosingFence, parseOpeningFence, readLine, type MarkdownFence } from "../translation2/entities/fences"
import { messageFormIdPattern } from "./messageForms"

export const messageWidgetLimits = {
  maxPerMessage: 1,
  maxIdLength: 64,
  maxTitleLength: 256,
  maxHtmlBytes: 256 * 1024,
  minHeight: 80,
  maxHeight: 2_000,
  maxImages: 16,
  maxCallNameLength: 64,
  maxCallPayloadBytes: 4 * 1024,
} as const

export const defaultWidgetId = "widget"
// AFM's reference renderer uses the same label for an untitled preview.
export const defaultWidgetTitle = "HTML preview"

/** A widget problem the sending bot can fix. The message never includes widget content. */
export class MessageWidgetError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "MessageWidgetError"
  }
}

function lineAt(source: string, index: number): number {
  let line = 1
  for (let cursor = source.indexOf("\n"); cursor >= 0 && cursor < index; cursor = source.indexOf("\n", cursor + 1)) line++
  return line
}

const htmlRules: ReadonlyArray<readonly [RegExp, string]> = [
  // Viewport units loop with auto height: the frame grows, so the viewport grows.
  [/\d(?:\.\d+)?[sld]?vh\b/i, "`vh` units; use px or let the content set the height"],
  [/<(?:iframe|frame|object|embed)\b/i, "a nested iframe, frame, object or embed"],
  [/<input\b[^>]*\btype\s*=\s*["']?password\b/i, "a password input; ask for secrets with a form block's secret field"],
]

/** The first rule the HTML breaks, with its line, or undefined when it passes. */
export function widgetHtmlProblem(html: string): string | undefined {
  if (html.trim().length === 0) return "Widget HTML is empty"
  if (Buffer.byteLength(html, "utf8") > messageWidgetLimits.maxHtmlBytes) return "Widget HTML exceeds 256 KiB"
  for (const [pattern, rule] of htmlRules) {
    const match = pattern.exec(html)
    if (match) return `Widget HTML has ${rule} (line ${lineAt(html, match.index)})`
  }
  return undefined
}

export function validWidgetId(id: string): boolean {
  return id.length >= 1 && id.length <= messageWidgetLimits.maxIdLength && messageFormIdPattern.test(id)
}

/** Structural checks for a widget block; text ranges and images are checked by the caller. */
export function validateWidgetDefinition(
  widget: BlockWidget,
  validateText: (range: BlockText | undefined) => void,
  validateImage: (image: BlockImage) => void,
): void {
  if (!validWidgetId(widget.widgetId)) throw new MessageWidgetError("Invalid widget id")
  validateText(widget.title)
  if (widget.title!.length === 0n) throw new MessageWidgetError("Widget title is empty")
  const problem = widgetHtmlProblem(widget.html)
  if (problem) throw new MessageWidgetError(problem)
  if (widget.height !== undefined
    && (!Number.isInteger(widget.height) || widget.height < messageWidgetLimits.minHeight || widget.height > messageWidgetLimits.maxHeight)) {
    throw new MessageWidgetError("Widget height must be 80 to 2000")
  }
  if (widget.images.length > messageWidgetLimits.maxImages) throw new MessageWidgetError("Too many widget images")
  for (const image of widget.images) validateImage(image)
  if (widget.requiredGrant < AgentGrantRequirement.NONE || widget.requiredGrant > AgentGrantRequirement.OWNER) {
    throw new MessageWidgetError("Invalid widget grant")
  }
}

function visitWidgets(blocks: readonly Block[], visit: (widget: BlockWidget) => void): void {
  for (const block of blocks) {
    switch (block.kind.oneofKind) {
      case "widget":
        visit(block.kind.widget)
        break
      case "disclosure":
        visitWidgets(block.kind.disclosure.children, visit)
        break
      case "quote":
        visitWidgets(block.kind.quote.children, visit)
        break
      case "callout":
        visitWidgets(block.kind.callout.children, visit)
        break
      case "list":
        for (const item of block.kind.list.items) visitWidgets(item.children, visit)
        break
    }
  }
}

export function findWidget(content: BlockContent | null | undefined, widgetId: string): BlockWidget | undefined {
  let found: BlockWidget | undefined
  if (content) visitWidgets(content.blocks, (widget) => {
    if (!found && widget.widgetId === widgetId) found = widget
  })
  return found
}

/** A validated `inline.action(name, payload)` call; the payload is parsed JSON. */
export type ValidatedWidgetCall = {
  call: MessageWidgetCall
  payload: unknown
}

export function validateWidgetCall(call: MessageWidgetCall): ValidatedWidgetCall {
  const name = call.name.trim()
  if (name.length < 1 || name.length > messageWidgetLimits.maxCallNameLength || !messageFormIdPattern.test(name)) {
    throw new MessageWidgetError("Invalid widget call name")
  }
  if (call.payload.byteLength > messageWidgetLimits.maxCallPayloadBytes) throw new MessageWidgetError("Widget call payload is too large")
  if (call.payload.byteLength === 0) return { call: { name, payload: new Uint8Array() }, payload: undefined }
  let payload: unknown
  try {
    payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(call.payload))
  } catch {
    throw new MessageWidgetError("Widget call payload must be UTF-8 JSON")
  }
  return { call: { name, payload: call.payload }, payload }
}

// MARK: Markdown

/** A widget written as an AFM HTML preview: `<iframe title="…">HTML</iframe>`. */
export type MarkdownWidget = {
  widgetId: string
  title: string
  html: string
  height?: number
}

export type ExtractedMarkdownWidget = {
  /** The Markdown with the preview replaced by its title, as a literal paragraph. */
  markdown: string
  widget: MarkdownWidget
  /** The title paragraph's range in `markdown`. */
  titleStart: number
  titleEnd: number
}

const iframeOpener = /^<iframe(?=[\s>])((?:[^"'<>]|"[^"]*"|'[^']*')*)>/i
const iframeCloser = /<\/iframe\s*>/gi
const attributePattern = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g

function decodeAttribute(value: string): string {
  return value.replace(/&(quot|amp|lt|gt|#39|apos);/g, (_, name: string) =>
    ({ quot: "\"", amp: "&", lt: "<", gt: ">", "#39": "'", apos: "'" })[name] ?? "")
}

function parseAttributes(source: string): Map<string, string> {
  const attributes = new Map<string, string>()
  for (const match of source.matchAll(attributePattern)) {
    const name = match[1]!.toLowerCase()
    if (!attributes.has(name)) attributes.set(name, decodeAttribute(match[2] ?? match[3] ?? match[4] ?? ""))
  }
  return attributes
}

// Every ASCII punctuation character is escapable in CommonMark, so the title stays literal.
function escapeMarkdownLiteral(text: string): string {
  return text.replace(/[!-/:-@[-`{-~]/g, "\\$&")
}

function widgetFromAttributes(attributes: Map<string, string>, html: string): MarkdownWidget {
  const widgetId = attributes.get("id")?.trim() || defaultWidgetId
  if (!validWidgetId(widgetId)) throw new MessageWidgetError("Invalid widget id")
  const title = (attributes.get("title") ?? "").replace(/\s+/g, " ").trim().slice(0, messageWidgetLimits.maxTitleLength)
    || defaultWidgetTitle
  const heightAttribute = attributes.get("height")?.trim()
  let height: number | undefined
  if (heightAttribute) {
    const parsed = /^(\d{1,6})(?:px)?$/.exec(heightAttribute)
    if (!parsed) throw new MessageWidgetError("Widget height must be a number of CSS pixels")
    height = Math.min(messageWidgetLimits.maxHeight, Math.max(messageWidgetLimits.minHeight, Number(parsed[1])))
  }
  return { widgetId, title, html, ...(height === undefined ? {} : { height }) }
}

/**
 * Finds the message's AFM HTML preview outside code fences. The opening tag
 * starts a line and the first closing tag ends the payload, which is literal.
 * Returns undefined when there is none; throws when the preview is malformed
 * or there is more than one.
 */
export function extractMarkdownWidget(markdown: string): ExtractedMarkdownWidget | undefined {
  let found: { start: number; end: number; widget: MarkdownWidget } | undefined
  let fence: MarkdownFence | undefined
  let cursor = 0
  while (cursor < markdown.length) {
    const line = readLine(markdown, cursor)
    if (fence) {
      if (isClosingFence(line.value, fence)) fence = undefined
      cursor = line.next
      continue
    }
    const openingFence = parseOpeningFence(line.value)
    if (openingFence) {
      fence = openingFence
      cursor = line.next
      continue
    }
    const opener = iframeOpener.exec(markdown.slice(line.start, line.contentEnd))
    if (!opener) {
      cursor = line.next
      continue
    }
    if (found) throw new MessageWidgetError("A message can have one widget")
    const bodyStart = line.start + opener[0].length
    iframeCloser.lastIndex = bodyStart
    const closer = iframeCloser.exec(markdown)
    if (!closer) throw new MessageWidgetError("Widget is missing its closing </iframe>")
    const closingLine = readLine(markdown, markdown.lastIndexOf("\n", closer.index) + 1)
    if (markdown.slice(closer.index + closer[0].length, closingLine.contentEnd).trim().length > 0) {
      throw new MessageWidgetError("Widget's closing </iframe> must end its line")
    }
    const html = markdown.slice(bodyStart, closer.index).replace(/^\r?\n/, "").replace(/\r?\n$/, "")
    found = { start: line.start, end: closingLine.contentEnd, widget: widgetFromAttributes(parseAttributes(opener[1] ?? ""), html) }
    cursor = closingLine.next
  }
  if (!found) return undefined

  // The title becomes its own paragraph, wherever the preview sat.
  const before = markdown.slice(0, found.start)
  const after = markdown.slice(found.end)
  const blankBefore = before.length === 0 || /\n[ \t]*\r?\n$/.test(before) || /^[ \t]*\r?\n?$/.test(before) ? "" : "\n"
  const blankAfter = after.length === 0 || /^\r?\n[ \t]*(?:\r?\n|$)/.test(after) ? "" : "\n"
  const title = escapeMarkdownLiteral(found.widget.title)
  const titleStart = before.length + blankBefore.length
  return {
    markdown: `${before}${blankBefore}${title}${blankAfter}${after}`,
    widget: found.widget,
    titleStart,
    titleEnd: titleStart + title.length,
  }
}

/** Replaces the paragraph whose text is exactly [start, end) with the widget. */
export function attachMarkdownWidget(content: BlockContent, start: number, end: number, widget: MarkdownWidget): boolean {
  const replace = (blocks: Block[]): boolean => {
    for (const [index, block] of blocks.entries()) {
      switch (block.kind.oneofKind) {
        case "paragraph": {
          const paragraph = block.kind.paragraph
          if (paragraph.offset !== BigInt(start) || paragraph.length !== BigInt(end - start)) break
          blocks[index] = {
            kind: {
              oneofKind: "widget",
              widget: {
                widgetId: widget.widgetId,
                title: paragraph,
                html: widget.html,
                ...(widget.height === undefined ? {} : { height: widget.height }),
                images: [],
                requiredGrant: AgentGrantRequirement.NONE,
              },
            },
          }
          return true
        }
        case "disclosure":
          if (replace(block.kind.disclosure.children)) return true
          break
        case "quote":
          if (replace(block.kind.quote.children)) return true
          break
        case "callout":
          if (replace(block.kind.callout.children)) return true
          break
        case "list":
          for (const item of block.kind.list.items) if (replace(item.children)) return true
          break
      }
    }
    return false
  }
  return replace(content.blocks)
}
