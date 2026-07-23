const INLINE_FORMATTING_RULES = [
  "Use Inline markdown.",
  "Prefer bullet lists over markdown tables.",
  "If a table is necessary, render it inside a fenced code block.",
  "Use plain URLs or markdown links; do not wrap bare URLs in inline code or backticks.",
  "Mention Inline users with markdown links like [@FirstName](inline://user?id=123); use inline://user?username=username only when the user id is unavailable.",
  "Link Inline chats/threads with markdown links like [Planning](inline://chat?id=123) or [Planning](inline://thread?id=123); use inline://thread?space_id=7 when only the title and space are known.",
  "Use inline code only for actual code, commands, file paths, env vars, or identifiers.",
  "Keep ordinary quoted prose, names, titles, statuses, and natural-language labels as plain text; quotation marks do not make text code.",
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

function normalizeInlineMarkdownLabel(raw: string | null | undefined, fallback: string): string {
  return (raw ?? "").replace(/\s+/g, " ").trim() || fallback
}

function escapeInlineMarkdownLabel(raw: string): string {
  return raw.replace(/\\/g, "\\\\").replace(/\[/g, "\\[").replace(/\]/g, "\\]")
}

function encodeInlineMarkdownValue(raw: string | number | bigint): string {
  return encodeURIComponent(String(raw).trim())
}

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

export function buildInlineUserMarkdownLink(params: {
  userId: string | number | bigint
  label?: string | null
  username?: string | null
}): string {
  const userId = encodeInlineMarkdownValue(params.userId)
  const username = params.username?.trim()
  const fallback = username ? `@${username.replace(/^@/, "")}` : `user:${String(params.userId)}`
  const rawLabel = normalizeInlineMarkdownLabel(params.label, fallback)
  const label = rawLabel.startsWith("@") ? rawLabel : `@${rawLabel}`
  return `[${escapeInlineMarkdownLabel(label)}](inline://user?id=${userId})`
}

export function buildInlineChatMarkdownLink(params: {
  chatId: string | number | bigint
  title?: string | null
}): string {
  const title = normalizeInlineMarkdownLabel(params.title, `chat:${String(params.chatId)}`)
  return `[${escapeInlineMarkdownLabel(title)}](inline://chat?id=${encodeInlineMarkdownValue(params.chatId)})`
}

export function buildInlineThreadMarkdownLink(params: {
  threadId: string | number | bigint
  title?: string | null
}): string {
  const title = normalizeInlineMarkdownLabel(params.title, `thread:${String(params.threadId)}`)
  return `[${escapeInlineMarkdownLabel(title)}](inline://thread?id=${encodeInlineMarkdownValue(params.threadId)})`
}

export function buildInlineThreadTitleMarkdownLink(params: {
  spaceId: string | number | bigint
  title: string
  label?: string | null
}): string {
  const title = normalizeInlineMarkdownLabel(params.title, `space:${String(params.spaceId)}`)
  const label = normalizeInlineMarkdownLabel(params.label, title)
  const query = [`space_id=${encodeInlineMarkdownValue(params.spaceId)}`]
  if (label !== title) {
    query.push(`title=${encodeInlineMarkdownValue(title)}`)
  }
  return `[${escapeInlineMarkdownLabel(label)}](inline://thread?${query.join("&")})`
}

export function sanitizeInlineOutgoingText(text: string): string {
  return adaptInlineVisibleCopy(text).replace(/`([^`\n]+)`/g, (full, content: string) => {
    return isBareHttpUrl(content) ? content : full
  })
}
