/**
 * Inline message widgets: sandboxed HTML a bot sends as an Agent Flavored
 * Markdown HTML preview. The server turns the block into a widget and keeps
 * only its title in the text:
 *
 *   <iframe title="Q3 revenue" id="revenue" height="420">
 *   <div class="card">…</div>
 *   </iframe>
 *
 * The scanner mirrors the server: the opener starts a line outside code
 * fences, and the first closing tag ends the literal payload and its line.
 */

export const INLINE_WIDGET_MAX_HTML_BYTES = 256 * 1024
export const INLINE_MESSAGE_MAX_UTF16_UNITS = 100_000
export const INLINE_WIDGET_DEFAULT_TITLE = "HTML preview"
export const INLINE_WIDGET_DEFAULT_HEIGHT = 400
const INLINE_WIDGET_MIN_HEIGHT = 80
const INLINE_WIDGET_MAX_HEIGHT = 2_000
const INLINE_WIDGET_MAX_ID_LENGTH = 64
const INLINE_WIDGET_MAX_TITLE_LENGTH = 256

const WIDGET_OPENER = /^<iframe(?=[\s>])((?:[^"'<>]|"[^"]*"|'[^']*')*)>/i
const WIDGET_CLOSER = /<\/iframe\s*>/gi
const utf8Encoder = new TextEncoder()

export class InlineWidgetError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "InlineWidgetError"
  }
}

type MarkdownLine = { start: number; contentEnd: number; next: number; value: string }
type MarkdownFence = { character: string; length: number }

function readLine(text: string, start: number): MarkdownLine {
  const newline = text.indexOf("\n", start)
  const rawEnd = newline >= 0 ? newline : text.length
  const contentEnd = rawEnd > start && text[rawEnd - 1] === "\r" ? rawEnd - 1 : rawEnd
  return { start, contentEnd, next: rawEnd < text.length ? rawEnd + 1 : text.length, value: text.slice(start, contentEnd) }
}

function parseOpeningFence(line: string): MarkdownFence | undefined {
  const match = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line)
  const run = match?.[1]
  if (!run) return undefined
  if (run[0] === "`" && (match?.[2] ?? "").includes("`")) return undefined
  return { character: run[0]!, length: run.length }
}

function isClosingFence(line: string, fence: MarkdownFence): boolean {
  const run = /^ {0,3}(`+|~+)[ \t]*$/.exec(line)?.[1]
  return run?.[0] === fence.character && run.length >= fence.length
}

/** A widget block: `start` is its opener's line start, `end` its closing line's end. */
export type InlineWidgetSpan = { start: number; end: number; closed: boolean }

type InlineWidgetScan = { spans: InlineWidgetSpan[]; endsInFence: boolean }

function scanInlineWidgets(text: string): InlineWidgetScan {
  const spans: InlineWidgetSpan[] = []
  let fence: MarkdownFence | undefined
  let cursor = 0
  while (cursor < text.length) {
    const line = readLine(text, cursor)
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
    const opener = WIDGET_OPENER.exec(line.value)
    if (!opener) {
      cursor = line.next
      continue
    }
    WIDGET_CLOSER.lastIndex = line.start + opener[0].length
    const closer = WIDGET_CLOSER.exec(text)
    if (!closer) {
      spans.push({ start: line.start, end: text.length, closed: false })
      break
    }
    const closingLine = readLine(text, text.lastIndexOf("\n", closer.index) + 1)
    spans.push({ start: line.start, end: closingLine.contentEnd, closed: true })
    cursor = closingLine.next
  }
  return { spans, endsInFence: fence !== undefined }
}

export function findInlineWidgetSpans(text: string): InlineWidgetSpan[] {
  return scanInlineWidgets(text).spans
}

/** Applies `transform` to the Markdown around widget blocks, leaving widget HTML untouched. */
export function mapInlineTextOutsideWidgets(text: string, transform: (segment: string) => string): string {
  const spans = findInlineWidgetSpans(text)
  if (spans.length === 0) return transform(text)
  let result = ""
  let cursor = 0
  for (const span of spans) {
    result += transform(text.slice(cursor, span.start)) + text.slice(span.start, span.end)
    cursor = span.end
  }
  return result + transform(text.slice(cursor))
}

function trimProse(text: string): string {
  return text.replace(/^(?:[ \t]*\r?\n)+/, "").trimEnd()
}

/**
 * Chunks Markdown with `chunk`, keeping every widget block whole and at most
 * one widget per message. The paragraph before a widget stays with it when the
 * message fits Inline's text limit; a short paragraph after it joins when the
 * combined message fits `limit`.
 */
export function chunkInlineMarkdownWithWidgets(
  text: string,
  limit: number,
  chunk: (text: string, limit: number) => string[],
): string[] {
  const spans = findInlineWidgetSpans(text)
  if (spans.length === 0) return chunk(text, limit)
  const chunkProse = (segment: string): string[] => {
    const prose = trimProse(segment)
    return prose.trim() ? chunk(prose, limit).filter((piece) => piece.trim()) : []
  }
  const messages: string[] = []
  let widgetMessage = -1
  let cursor = 0
  for (const span of spans) {
    const pieces = chunkProse(text.slice(cursor, span.start))
    const widget = text.slice(span.start, span.end)
    const previous = widgetMessage >= 0 ? messages[widgetMessage] : undefined
    if (pieces.length >= 2 && previous !== undefined && previous.length + 2 + pieces[0]!.length <= limit) {
      messages[widgetMessage] = `${previous}\n\n${pieces.shift()!}`
    }
    const lead = pieces.pop()
    messages.push(...pieces)
    if (lead !== undefined && lead.length + 2 + widget.length <= INLINE_MESSAGE_MAX_UTF16_UNITS) {
      messages.push(`${lead}\n\n${widget}`)
    } else {
      if (lead !== undefined) messages.push(lead)
      messages.push(widget)
    }
    widgetMessage = messages.length - 1
    cursor = span.end
  }
  const tail = chunkProse(text.slice(cursor))
  const last = messages[widgetMessage]!
  if (tail.length > 0 && last.length + 2 + tail[0]!.length <= limit) {
    messages[widgetMessage] = `${last}\n\n${tail.shift()!}`
  }
  messages.push(...tail)
  return messages
}

/** Splits text into messages that each carry at most one widget, without length chunking. */
export function splitInlineWidgetMessages(text: string): string[] {
  return chunkInlineMarkdownWithWidgets(text, INLINE_MESSAGE_MAX_UTF16_UNITS, (segment) => [segment])
}

function isPartialWidgetOpenerLine(line: string): boolean {
  const lowered = line.toLowerCase()
  if (!lowered.startsWith("<")) return false
  return "<iframe".startsWith(lowered) || /^<iframe\s/.test(lowered)
}

/**
 * Separates streamed text that can be shown now from an unfinished widget at
 * its end. `held` starts at the widget opener (or a partially streamed opener
 * line) and must wait for more text.
 */
export function splitInlineWidgetStreamTail(text: string): { ready: string; held: string } {
  const { spans, endsInFence } = scanInlineWidgets(text)
  const last = spans.at(-1)
  if (last && !last.closed) {
    return { ready: text.slice(0, last.start).trimEnd(), held: text.slice(last.start) }
  }
  if (!endsInFence) {
    const lineStart = text.lastIndexOf("\n") + 1
    if (lineStart >= (last?.end ?? 0) && isPartialWidgetOpenerLine(text.slice(lineStart))) {
      return { ready: text.slice(0, lineStart).trimEnd(), held: text.slice(lineStart) }
    }
  }
  return { ready: text, held: "" }
}

/** Streaming state that holds an unfinished widget back until it closes. */
export type InlineWidgetStreamHoldback = { held: string }

/**
 * Returns the text to deliver now for one streamed block. Without `flush`, an
 * unclosed widget at the end is kept for the next block; with `flush`, any
 * held text is released as is.
 */
export function takeInlineWidgetStreamText(
  state: InlineWidgetStreamHoldback,
  text: string,
  options: { flush: boolean },
): string {
  const combined = state.held ? (text.trim() ? `${state.held}\n${text}` : state.held) : text
  state.held = ""
  if (options.flush) return combined
  const split = splitInlineWidgetStreamTail(combined)
  state.held = split.held
  return split.ready
}

// MARK: Building a widget block

export function escapeInlineWidgetAttribute(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

function normalizeInlineWidgetTitle(raw: string | undefined): string {
  const title = (raw ?? "").replace(/\s+/g, " ").trim()
  return Array.from(title).slice(0, INLINE_WIDGET_MAX_TITLE_LENGTH).join("") || INLINE_WIDGET_DEFAULT_TITLE
}

/** A stable widget id (`[A-Za-z0-9_.:-]`, at most 64) derived from a title. */
export function deriveInlineWidgetId(title: string | undefined): string {
  const slug = (title ?? "")
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9_.:-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, INLINE_WIDGET_MAX_ID_LENGTH)
    .replace(/-+$/g, "")
  return slug || "widget"
}

/** The first problem Inline would reject the widget HTML for, checked before sending. */
export function inlineWidgetHtmlProblem(html: string): string | undefined {
  if (!html.trim()) return "Widget HTML is empty"
  const tag = /<\/?iframe\b/i.exec(html)
  if (tag) {
    return tag[0].startsWith("</")
      ? "Widget HTML cannot contain </iframe: Inline ends the widget at the first closing iframe tag"
      : "Widget HTML cannot contain a nested <iframe>"
  }
  const bytes = utf8Encoder.encode(html).byteLength
  if (bytes > INLINE_WIDGET_MAX_HTML_BYTES) {
    return `Widget HTML is ${bytes} bytes; Inline allows ${INLINE_WIDGET_MAX_HTML_BYTES}`
  }
  return undefined
}

/** Builds one Inline widget message. Throws InlineWidgetError when Inline would reject it. */
export function buildInlineWidgetMarkdown(params: {
  html: string
  title?: string
  id?: string
  height?: number
}): string {
  const html = params.html.trim()
  const problem = inlineWidgetHtmlProblem(html)
  if (problem) throw new InlineWidgetError(problem)
  const title = normalizeInlineWidgetTitle(params.title)
  const id = params.id?.trim() || deriveInlineWidgetId(title)
  if (id.length > INLINE_WIDGET_MAX_ID_LENGTH || !/^[A-Za-z0-9_.:-]+$/.test(id)) {
    throw new InlineWidgetError(`Invalid widget id "${id}": use up to 64 of A-Z a-z 0-9 _ . : -`)
  }
  const rawHeight = params.height ?? INLINE_WIDGET_DEFAULT_HEIGHT
  const height = Math.min(
    INLINE_WIDGET_MAX_HEIGHT,
    Math.max(INLINE_WIDGET_MIN_HEIGHT, Number.isFinite(rawHeight) ? Math.round(rawHeight) : INLINE_WIDGET_DEFAULT_HEIGHT),
  )
  const text =
    `<iframe title="${escapeInlineWidgetAttribute(title)}" id="${escapeInlineWidgetAttribute(id)}" height="${height}">\n` +
    `${html}\n</iframe>`
  if (text.length > INLINE_MESSAGE_MAX_UTF16_UNITS) {
    throw new InlineWidgetError(
      `Widget message is ${text.length} UTF-16 units; Inline messages allow ${INLINE_MESSAGE_MAX_UTF16_UNITS}`,
    )
  }
  return text
}

// MARK: OpenClaw show_widget documents

// Every OpenClaw host bridge script starts this way; widget code never does.
const OPENCLAW_BRIDGE_SCRIPT_PREFIX = "<script>(()=>{if(!window.parent||window.parent===window"
const SCRIPT_CLOSE = "</script>"

/**
 * OpenClaw passes presenters its full Canvas document: a head with its own
 * stylesheet and CSP, then host bridge scripts around the agent's widget code.
 * Inline wraps widget HTML in its own sandbox, theme and bridge, so only the
 * agent's code is kept. Anything that is not such a document is returned as is.
 */
export function extractOpenClawWidgetSource(document: string): string {
  if (!/^\s*<!doctype html>/i.test(document)) return document.trim()
  const headEnd = document.search(/<\/head>/i)
  if (headEnd < 0) return document.trim()
  const bodyOpen = /<body\b[^>]*>/i.exec(document.slice(headEnd))
  if (!bodyOpen) return document.trim()
  let body = document
    .slice(headEnd + bodyOpen.index + bodyOpen[0].length)
    .replace(/<\/body>\s*<\/html>\s*$/i, "")
  while (body.startsWith(OPENCLAW_BRIDGE_SCRIPT_PREFIX)) {
    const end = body.indexOf(SCRIPT_CLOSE)
    if (end < 0) break
    body = body.slice(end + SCRIPT_CLOSE.length)
  }
  while (body.endsWith(SCRIPT_CLOSE)) {
    const start = body.lastIndexOf(OPENCLAW_BRIDGE_SCRIPT_PREFIX)
    if (start < 0 || body.indexOf(SCRIPT_CLOSE, start) !== body.length - SCRIPT_CLOSE.length) break
    body = body.slice(0, start)
  }
  return body.trim()
}

/**
 * Maps OpenClaw's widget theme names that Inline does not define onto Inline's
 * theme, and gives `openclaw.prompt.send` to code written for OpenClaw.
 * Inline already defines `sendPrompt`. `--muted` and `--accent` keep Inline's
 * meaning (subtle fills).
 */
export const OPENCLAW_WIDGET_COMPAT_PRELUDE =
  "<style>:root{--text:var(--foreground);--text-strong:var(--foreground);--surface:var(--background);" +
  "--elevated:var(--card);--accent-fill:var(--primary);--accent-fg:var(--primary-foreground);" +
  "--ok:var(--success);--warn:var(--warning);--danger:var(--destructive);--font-body:var(--font-sans);" +
  "--accent-subtle:var(--accent);--ok-subtle:var(--success-surface);--warn-subtle:var(--warning-surface);" +
  "--danger-subtle:var(--destructive-surface);--info-subtle:var(--accent)}</style>\n" +
  "<script>(()=>{if(window.openclaw||!window.inline)return;const send=t=>window.inline.sendPrompt(String(t));" +
  "window.openclaw=Object.freeze({prompt:Object.freeze({send})})})()</script>"

/** Widget HTML for Inline from an OpenClaw show_widget document. */
export function buildInlineWidgetHtmlFromOpenClaw(document: string): string {
  const source = extractOpenClawWidgetSource(document)
  if (!source) return ""
  return `${OPENCLAW_WIDGET_COMPAT_PRELUDE}\n${source}`
}
