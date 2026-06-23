import { normalizeMarkdownText, parseMarkdownOutput } from "@inline-chat/markdown"
import { cleanInlineMarkdown } from "./inlineMarkdown"

const MARKDOWN_IMAGE_SCAN_LIMIT = 256
const MAX_FINAL_RICH_MARKDOWN_CHARS = 24_000

export type ChatgptMarkdownOutput = {
  readonly text: string
}

export function cleanStreamingMarkdown(text: string): string {
  const parsed = parseMarkdownOutput(text, {
    maxImages: MARKDOWN_IMAGE_SCAN_LIMIT,
  })
  return cleanInlineMarkdown(parsed.text)
}

export function parseChatgptMarkdownOutput(text: string): ChatgptMarkdownOutput {
  return {
    text: cleanFinalRichMarkdown(text),
  }
}

function cleanFinalRichMarkdown(text: string): string {
  const normalized = normalizeMarkdownText(text.replace(/\r\n?/g, "\n")).replace(/[ \t]+\n/g, "\n").trim()
  const bounded = normalized.length > MAX_FINAL_RICH_MARKDOWN_CHARS
    ? `${normalized.slice(0, MAX_FINAL_RICH_MARKDOWN_CHARS - 32).trimEnd()}\n\n[truncated]`
    : normalized
  return closeDanglingCodeFence(bounded)
}

function closeDanglingCodeFence(text: string): string {
  const matches = text.match(/```/g)
  if (!matches || matches.length % 2 === 0) {
    return text
  }
  return `${text}\n\`\`\``
}
