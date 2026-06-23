import { RichDirection, type RichMessage } from "@inline-chat/realtime-sdk"
import type { ResolvedInlineAccount } from "./accounts.js"

export type InlineTextParseOptions =
  | { parseRichMarkdown: true; parseMarkdown?: never }
  | { parseMarkdown: boolean; parseRichMarkdown?: never }
export type InlineStreamingTextOptions =
  | { richText: RichMessage; parseMarkdown?: never; parseRichMarkdown?: never }
  | InlineTextParseOptions
export type InlineStreamingTextDraft = {
  readonly text: string
  readonly options: InlineStreamingTextOptions
}

const RICH_TEXT_MAX_TEXT_LENGTH = 32_768
const RICH_TEXT_MAX_BLOCKS = 500

export function inlineTextParseOptions(account: ResolvedInlineAccount): InlineTextParseOptions {
  if (account.config.parseMarkdown === false) {
    return { parseMarkdown: false }
  }

  // Prefer Inline rich blocks for modern clients; `parseMarkdown` remains the explicit
  // fallback/disable knob until OpenClaw grows a dedicated per-account rich-text flag.
  return { parseRichMarkdown: true }
}

export function inlineCaptionParseOptions(
  account: ResolvedInlineAccount,
  caption: string,
): InlineTextParseOptions | Record<string, never> {
  if (!caption) {
    return {}
  }
  return inlineTextParseOptions(account)
}

export function inlineStreamingTextOptions(
  account: ResolvedInlineAccount,
  text: string,
): InlineStreamingTextOptions {
  if (account.config.parseMarkdown === false) {
    return { parseMarkdown: false }
  }

  return { richText: buildInlineStreamingRichText(text) }
}

export function prepareInlineStreamingTextDraft(
  account: ResolvedInlineAccount,
  text: string,
): InlineStreamingTextDraft | undefined {
  const trimmed = text.trim()
  if (!trimmed) {
    return undefined
  }

  if (account.config.parseMarkdown === false) {
    return {
      text: trimmed,
      options: { parseMarkdown: false },
    }
  }

  const richText = buildInlineStreamingRichText(trimmed)
  if (!richText.fallbackText) {
    return undefined
  }

  return {
    text: richText.fallbackText,
    options: { richText },
  }
}

export function buildInlineStreamingRichText(text: string): RichMessage {
  const fallbackText = normalizeStreamingText(text)
  const paragraphs = fallbackText
    .split(/\n{2,}/u)
    .map((paragraph) => paragraph.trim())
    .filter(Boolean)
    .slice(0, RICH_TEXT_MAX_BLOCKS)

  return {
    blocks: paragraphs.map((paragraph, index) => ({
      blockId: `openclaw_stream_visible_${index}`,
      direction: RichDirection.DIRECTION_AUTO,
      block: {
        oneofKind: "paragraph",
        paragraph: {
          text: [
            {
              text: paragraph,
              children: [],
              styles: [],
            },
          ],
        },
      },
    })),
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText,
    version: 1,
  }
}

export function buildInlineProgressDraftRichText(text: string): RichMessage {
  const fallbackText = normalizeStreamingText(text)
  const lines = fallbackText
    .split(/\n+/u)
    .map((line) => line.trim())
    .filter(Boolean)
  return buildInlineProgressDraftRichTextFromLines(text, lines)
}

export type InlineProgressDraftLineMeta = {
  readonly id?: string
  readonly kind?: string
  readonly toolName?: string
  readonly label?: string
  readonly status?: string
}

export function buildInlineProgressDraftRichTextFromLines(
  text: string,
  lines: readonly (string | InlineProgressDraftLineMeta)[] = [],
): RichMessage {
  const fallbackText = normalizeStreamingText(text)
  const visibleLines = fallbackText
    .split(/\n+/u)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, RICH_TEXT_MAX_BLOCKS - 1)
  const visibleMeta = visibleProgressLineMeta(visibleLines.length, lines)

  return {
    blocks: [
      {
        blockId: "openclaw_progress_thinking",
        direction: RichDirection.DIRECTION_AUTO,
        block: {
          oneofKind: "thinking",
          thinking: {
            initiallyCollapsed: false,
            blocks: visibleLines.map((line, index) => ({
              blockId: progressLineBlockId(visibleMeta[index], index),
              direction: RichDirection.DIRECTION_AUTO,
              block: {
                oneofKind: "paragraph",
                paragraph: {
                  text: [{ text: line, children: [], styles: [] }],
                },
              },
            })),
          },
        },
      },
    ],
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText,
    version: 1,
  }
}

function visibleProgressLineMeta(
  visibleLineCount: number,
  lines: readonly (string | InlineProgressDraftLineMeta)[],
): Array<string | InlineProgressDraftLineMeta | undefined> {
  if (visibleLineCount <= 0) {
    return []
  }

  if (lines.length === 0) {
    return Array.from({ length: visibleLineCount }, () => undefined)
  }

  const hasDraftLabel = visibleLineCount > lines.length
  const progressLineCount = hasDraftLabel ? visibleLineCount - 1 : visibleLineCount
  const visibleProgressLines = lines.slice(0, progressLineCount)
  return hasDraftLabel ? [undefined, ...visibleProgressLines] : visibleProgressLines
}

function progressLineBlockId(line: string | InlineProgressDraftLineMeta | undefined, index: number): string {
  if (!line) {
    return index === 0 ? "openclaw_progress_label" : `openclaw_progress_line_${index}`
  }
  if (typeof line === "string") {
    return `openclaw_progress_line_${index}`
  }

  const explicitId = safeBlockIdSegment(line.id)
  if (explicitId) {
    return `openclaw_progress_${explicitId}`
  }

  const semantic = [line.kind, line.toolName, line.label, line.status]
    .map(safeBlockIdSegment)
    .filter(Boolean)
    .join("_")
  return semantic ? `openclaw_progress_${semantic}_${index}` : `openclaw_progress_line_${index}`
}

function safeBlockIdSegment(value: string | undefined): string | undefined {
  const normalized = value?.trim().replace(/[^A-Za-z0-9_-]+/g, "_").replace(/^_+|_+$/g, "")
  return normalized || undefined
}

function normalizeStreamingText(text: string): string {
  const normalized = text.replace(/\r\n?/g, "\n")
  const cleaned = cleanupRemovedImageWhitespace(stripStreamingMarkdownImages(normalized))
  if (cleaned.length <= RICH_TEXT_MAX_TEXT_LENGTH) {
    return cleaned
  }
  return `${cleaned.slice(0, RICH_TEXT_MAX_TEXT_LENGTH - 3).trimEnd()}...`
}

function stripStreamingMarkdownImages(text: string): string {
  const lines = text.split("\n")
  let inFence = false

  return lines
    .map((line) => {
      if (isFenceBoundary(line)) {
        inFence = !inFence
        return line
      }
      return inFence ? line : stripMarkdownImagesFromLine(line)
    })
    .join("\n")
}

function stripMarkdownImagesFromLine(line: string): string {
  let output = ""
  let index = 0

  while (index < line.length) {
    if (line.startsWith("![", index)) {
      const labelEnd = findClosingBracket(line, index + 2)
      if (labelEnd !== undefined && line[labelEnd + 1] === "(") {
        const spanEnd = findClosingParen(line, labelEnd + 1)
        if (spanEnd !== undefined) {
          index = spanEnd
          continue
        }
      }
    }

    output += line[index] ?? ""
    index += 1
  }

  return output
}

function findClosingBracket(line: string, start: number): number | undefined {
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

function findClosingParen(line: string, openParen: number): number | undefined {
  let depth = 0
  for (let index = openParen + 1; index < line.length; index += 1) {
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
    return index + 1
  }
  return undefined
}

function cleanupRemovedImageWhitespace(text: string): string {
  const output: string[] = []
  let inFence = false

  for (const line of text.split("\n")) {
    if (isFenceBoundary(line)) {
      inFence = !inFence
      output.push(line)
      continue
    }

    if (inFence) {
      output.push(line)
      continue
    }

    const cleaned = line.replace(/[ \t]{2,}/g, " ").trimEnd()
    if (isBareListMarker(cleaned)) {
      continue
    }
    output.push(cleaned)
  }

  return output.join("\n").replace(/\n{3,}/g, "\n\n").trim()
}

function isFenceBoundary(line: string): boolean {
  return /^\s*(```|~~~)/.test(line)
}

function isBareListMarker(line: string): boolean {
  return /^\s*(?:[-*+]|\d{1,3}[.)])$/.test(line)
}
