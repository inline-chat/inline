export const INLINE_FORMATTING_NOTE =
  "Inline formatting note: prefer bullet lists over markdown tables. If a table is necessary, render it inside a fenced code block. Do not wrap bare URLs in inline code or backticks. Use plain URLs or markdown links. Use inline code only for actual code, commands, file paths, env vars, or identifiers."

const INLINE_SYSTEM_PROMPT_BASE =
  "Format replies for Inline. Prefer bullet lists over markdown tables. If a table is necessary, render it inside a fenced code block. Do not wrap bare URLs in inline code or backticks. Use plain URLs or markdown links. Use inline code only for actual code, commands, file paths, env vars, or identifiers."

function isBareHttpUrl(text: string): boolean {
  if (!/^https?:\/\/\S+$/i.test(text)) return false
  try {
    const url = new URL(text)
    return url.protocol === "http:" || url.protocol === "https:"
  } catch {
    return false
  }
}

export function buildInlineSystemPrompt(extraPrompt?: string): string {
  return [INLINE_SYSTEM_PROMPT_BASE, extraPrompt?.trim() || null]
    .filter((entry): entry is string => Boolean(entry))
    .join("\n\n")
}

export function sanitizeInlineOutgoingText(text: string): string {
  return text.replace(/`([^`\n]+)`/g, (full, content: string) => {
    return isBareHttpUrl(content) ? content : full
  })
}
