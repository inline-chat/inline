const INLINE_FORMATTING_RULES = [
  "Use Inline markdown.",
  "Prefer bullet lists over markdown tables.",
  "If a table is necessary, render it inside a fenced code block.",
  "Use plain URLs or markdown links; do not wrap bare URLs in inline code or backticks.",
  "Mention Inline users with markdown links like [@FirstName](inline://user?id=123); use inline://user?username=username only when the user id is unavailable.",
  "Link Inline chats/threads with markdown links like [Planning](inline://chat?id=123) or [Planning](inline://thread?id=123); use inline://thread?space_id=7 when only the title and space are known.",
  "Use inline code only for actual code, commands, file paths, env vars, or identifiers.",
]

const INLINE_COPY_REPLACEMENTS: Array<[RegExp, string]> = [
  [
    /Bind this (?:thread \(Discord\) or topic\/conversation \(Telegram\)|thread or topic\/conversation) to a session target\.?/gi,
    "Bind this Inline conversation to a session target.",
  ],
  [
    /Remove the current (?:thread \(Discord\) or topic\/conversation \(Telegram\)|thread or topic\/conversation) binding\.?/gi,
    "Remove the current Inline conversation binding.",
  ],
]

function isBareHttpUrl(text: string): boolean {
  if (!/^https?:\/\/\S+$/i.test(text)) return false
  try {
    const url = new URL(text)
    return url.protocol === "http:" || url.protocol === "https:"
  } catch {
    return false
  }
}

export function adaptInlineVisibleCopy(text: string): string {
  let result = text
  for (const [from, to] of INLINE_COPY_REPLACEMENTS) {
    result = result.replace(from, to)
  }
  return result
}

export function buildInlineSystemPrompt(extraPrompt?: string): string {
  return extraPrompt?.trim() || ""
}

export function buildInlineInboundFormattingHints(): { text_markup: string; rules: string[] } {
  return {
    text_markup: "inline_markdown",
    rules: [...INLINE_FORMATTING_RULES],
  }
}

export function sanitizeInlineOutgoingText(text: string): string {
  return adaptInlineVisibleCopy(text).replace(/`([^`\n]+)`/g, (full, content: string) => {
    return isBareHttpUrl(content) ? content : full
  })
}
