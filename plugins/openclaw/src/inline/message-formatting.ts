import { mapInlineTextOutsideWidgets } from "./widgets.js"

const INLINE_FORMATTING_RULES = [
  "Use Inline's supported Markdown: emphasis, inline or fenced code, links, headings, lists or checklists, quotes, tables, separators, and HTTP(S) images.",
  "Do not rely on strikethrough, footnotes, or arbitrary HTML (the one exception is a widget block); unrecognized or ambiguous incomplete syntax remains visible text.",
  'Widgets (sandboxed HTML in a message): only when Markdown or tables cannot show it, such as charts, diagrams, mockups, comparison grids, or small pickers; keep prose outside. Use the show_widget tool when available; otherwise write one block per message, with blank lines around it: a line <iframe title="Title" id="short-id" height="420">, the HTML, then a line </iframe>. Never put </iframe> inside the HTML.',
  "Widget sandbox: no network (no fetch, XHR, WebSocket, or remote images); inline scripts plus cdn.jsdelivr.net, cdnjs.cloudflare.com, unpkg.com, esm.sh; images as data: URIs. Avoid vh, position: fixed, and nested frames; stay responsive at 320-640px; set height to the content height at about 640px.",
  "Widget theme: --background --foreground --muted (fill) --muted-foreground --card --border --primary --primary-foreground --accent (tint) --success --warning --destructive --radius --font-sans --font-mono; classes .card .grid .row .badge .btn .btn-primary .btn-ghost .table .muted .small.",
  "Widget bridge, on the viewer's click: inline.copy(text); inline.sendPrompt(text) prefills the viewer's reply (sends directly in a 1:1 DM with you); inline.action(name, payload) reaches you as a widget call; inline.openLink(url); inline.setState(obj) and inline.state.",
  "Use ordinary Markdown tables for genuinely tabular data; never put a table in a fenced code block.",
  'For collapsible work, use <details open> followed by <summary>Title</summary>, body Markdown, and </details>; add kind="progress" to summary only while work is in progress.',
  "Use <footer>Attribution or brief metadata</footer> for a short message footer.",
  "Use plain URLs or markdown links; do not wrap bare URLs in inline code or backticks.",
  "Mention Inline users as [@FirstName](inline://user?id=123), falling back to [@username](inline://user?id=123). Use inline://user?username=username only when the user id is unavailable, and never show user:<id> as the visible label.",
  "Link Inline chats/threads with markdown links like [Planning](inline://chat?id=123) or [Planning](inline://thread?id=123); use inline://thread?space_id=7 when only the title and space are known.",
  "Use inline code only for actual code, commands, file paths, env vars, or identifiers.",
  "Keep ordinary quoted prose, names, titles, statuses, and natural-language labels as plain text; quotation marks do not make text code.",
]

type InlineCopyReplacement = [RegExp, string | ((match: string, ...groups: string[]) => string)]

const INLINE_APPROVAL_DECISION_COPY: Record<string, string> = {
  "allow-once": "Allowed once.",
  "allow-always": "Always allowed.",
  deny: "Denied.",
}

// OpenClaw writes these for every channel. Inline shows them shorter, the way
// Hermes and bridge v2 do: the result, not the ids and operator advice.
const INLINE_HOST_NOTICE_REPLACEMENTS: InlineCopyReplacement[] = [
  [
    /^✅ Approval (allow-once|allow-always|deny) submitted for [\w-]+\.$/,
    (_match, decision) => INLINE_APPROVAL_DECISION_COPY[decision] ?? "Answered.",
  ],
  [
    /^Approval required\. I sent the approval request to (.+?), not this chat\.$/,
    (_match, destination) =>
      destination === "Inline DMs" ? "Waiting for approval in your DM." : `Waiting for approval in ${destination}.`,
  ],
  [
    /^⚠️ OpenClaw couldn't produce or deliver a reply\. Please try again\. If this keeps happening, ask the operator to check the gateway logs\.(?: Reference: [\w-]+\.)?$/,
    "⚠️ Couldn't answer that. Try again.",
  ],
  [/^⚠️ The AI service returned an empty reply\. Please try again\.$/, "⚠️ Couldn't answer that. Try again."],
  [
    /^Current thinking level: ([^.\n]+)\.\nChoose level for \/think\.(?:\nOptions: [^\n]*)?$/,
    (_match, level) => `Thinking: ${level}`,
  ],
  [
    // The buttons browse providers; the typed /model syntax stays in /model status.
    /^Current: ([^\n]+)\n(?:Think: ([^\s(]+)[^\n]*\n)?Tap below to select a model, or use:\n[\s\S]*$/,
    (_match, model, think) => (think ? `Model: ${model}\nThinking: ${think}` : `Model: ${model}`),
  ],
]

// Before and after the Inline copy rewrite below; transformReplyPayload runs first.
const INLINE_HOST_NO_REPLY_FALLBACK = /^⚠️ (?:OpenClaw couldn't produce or deliver a reply\.|The AI service returned an empty reply\. Please try again\.$|Couldn't answer that\. Try again\.$)/

/** OpenClaw's notice for a turn that ended without a visible reply. */
export function isInlineHostNoReplyFallback(text: string | undefined | null): boolean {
  return typeof text === "string" && INLINE_HOST_NO_REPLY_FALLBACK.test(text.trim())
}

const INLINE_COPY_REPLACEMENTS: InlineCopyReplacement[] = [
  ...INLINE_HOST_NOTICE_REPLACEMENTS,
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
    result = typeof to === "string" ? result.replace(from, to) : result.replace(from, to as (...args: string[]) => string)
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
  const fallback = username ? `@${username.replace(/^@/, "")}` : "@user"
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
  // Widget HTML is literal: a JS template literal holding a URL must keep its backticks.
  return mapInlineTextOutsideWidgets(text, (segment) =>
    adaptInlineVisibleCopy(segment).replace(/`([^`\n]+)`/g, (full, content: string) => {
      return isBareHttpUrl(content) ? content : full
    }))
}
