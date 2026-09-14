import { sanitizeAssistantVisibleTextWithOptions } from "openclaw/plugin-sdk/text-chunking"

const HEARTBEAT_TOKEN = "HEARTBEAT_OK"
const OPENCLAW_RUNTIME_CONTEXT_NOTICE =
  "This context is runtime-generated, not user-authored. Keep internal details private."
const OPENCLAW_NEXT_TURN_RUNTIME_CONTEXT_HEADER =
  "OpenClaw runtime context for the immediately preceding user message."
const OPENCLAW_RUNTIME_EVENT_HEADER = "OpenClaw runtime event."
const OPENCLAW_LEGACY_RUNTIME_CONTEXT_HEADER = "OpenClaw runtime context (internal):"
const OPENCLAW_LEGACY_RUNTIME_CONTEXT_PREFACE =
  [OPENCLAW_LEGACY_RUNTIME_CONTEXT_HEADER, OPENCLAW_RUNTIME_CONTEXT_NOTICE, ""].join("\n") + "\n"
const OPENCLAW_INTERNAL_CONTEXT_BEGIN = "<<<BEGIN_OPENCLAW_INTERNAL_CONTEXT>>>"
const OPENCLAW_INTERNAL_CONTEXT_END = "<<<END_OPENCLAW_INTERNAL_CONTEXT>>>"
const OPENCLAW_LEGACY_INTERNAL_EVENT_MARKER = "[Internal task completion event]"
const OPENCLAW_LEGACY_INTERNAL_EVENT_SEPARATOR = "\n\n---\n\n"
const OPENCLAW_LEGACY_UNTRUSTED_RESULT_BEGIN = "<<<BEGIN_UNTRUSTED_CHILD_RESULT>>>"
const OPENCLAW_LEGACY_UNTRUSTED_RESULT_END = "<<<END_UNTRUSTED_CHILD_RESULT>>>"
export const INLINE_ACTION_LABEL_MAX_LENGTH = 64
export const INLINE_ACTION_CALLBACK_DATA_MAX_BYTES = 1024
export const INLINE_ACTION_COPY_TEXT_MAX_LENGTH = 4096

const utf8Encoder = new TextEncoder()

export type InlineSanitizedVisibleText = {
  text: string
  shouldSkip: boolean
  didStrip: boolean
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

function findDelimitedTokenIndex(text: string, token: string, from: number): number {
  const tokenRe = new RegExp(`(?:^|\\r?\\n)${escapeRegExp(token)}(?=\\r?\\n|$)`, "g")
  tokenRe.lastIndex = Math.max(0, from)
  const match = tokenRe.exec(text)
  if (!match) {
    return -1
  }
  const prefixLength = match[0].length - token.length
  return match.index + prefixLength
}

function stripDelimitedBlock(text: string, begin: string, end: string): string {
  let next = text
  for (;;) {
    const start = findDelimitedTokenIndex(next, begin, 0)
    if (start === -1) return next

    let cursor = start + begin.length
    let depth = 1
    let finish = -1
    while (depth > 0) {
      const nextBegin = findDelimitedTokenIndex(next, begin, cursor)
      const nextEnd = findDelimitedTokenIndex(next, end, cursor)
      if (nextEnd === -1) {
        break
      }
      if (nextBegin !== -1 && nextBegin < nextEnd) {
        depth += 1
        cursor = nextBegin + begin.length
        continue
      }
      depth -= 1
      finish = nextEnd
      cursor = nextEnd + end.length
    }

    const before = next.slice(0, start).trimEnd()
    if (finish === -1 || depth !== 0) return before
    const after = next.slice(finish + end.length).trimStart()
    next = before && after ? `${before}\n\n${after}` : `${before}${after}`
  }
}

function stripDelimitedRuntimeContext(text: string): { text: string; didStrip: boolean } {
  const next = stripDelimitedBlock(
    text,
    OPENCLAW_INTERNAL_CONTEXT_BEGIN,
    OPENCLAW_INTERNAL_CONTEXT_END,
  )
  return { text: next, didStrip: next !== text }
}

function findLegacyInternalEventEnd(text: string, start: number): number | null {
  if (!text.startsWith(OPENCLAW_LEGACY_INTERNAL_EVENT_MARKER, start)) {
    return null
  }

  const resultBegin = text.indexOf(
    OPENCLAW_LEGACY_UNTRUSTED_RESULT_BEGIN,
    start + OPENCLAW_LEGACY_INTERNAL_EVENT_MARKER.length,
  )
  if (resultBegin === -1) {
    return null
  }

  const resultEnd = text.indexOf(
    OPENCLAW_LEGACY_UNTRUSTED_RESULT_END,
    resultBegin + OPENCLAW_LEGACY_UNTRUSTED_RESULT_BEGIN.length,
  )
  if (resultEnd === -1) {
    return null
  }

  const actionIndex = text.indexOf(
    "\n\nAction:\n",
    resultEnd + OPENCLAW_LEGACY_UNTRUSTED_RESULT_END.length,
  )
  if (actionIndex === -1) {
    return null
  }

  const afterAction = actionIndex + "\n\nAction:\n".length
  const nextEvent = text.indexOf(
    `${OPENCLAW_LEGACY_INTERNAL_EVENT_SEPARATOR}${OPENCLAW_LEGACY_INTERNAL_EVENT_MARKER}`,
    afterAction,
  )
  if (nextEvent !== -1) {
    return nextEvent
  }

  const nextParagraph = text.indexOf("\n\n", afterAction)
  return nextParagraph === -1 ? text.length : nextParagraph
}

function stripLegacyInternalRuntimeContext(text: string): { text: string; didStrip: boolean } {
  let next = text
  let didStrip = false
  let searchFrom = 0
  for (;;) {
    const headerStart = next.indexOf(OPENCLAW_LEGACY_RUNTIME_CONTEXT_PREFACE, searchFrom)
    if (headerStart === -1) {
      return { text: next, didStrip }
    }

    const eventStart = headerStart + OPENCLAW_LEGACY_RUNTIME_CONTEXT_PREFACE.length
    if (!next.startsWith(OPENCLAW_LEGACY_INTERNAL_EVENT_MARKER, eventStart)) {
      searchFrom = eventStart
      continue
    }

    let blockEnd = findLegacyInternalEventEnd(next, eventStart)
    if (blockEnd == null) {
      const nextParagraph = next.indexOf(
        "\n\n",
        eventStart + OPENCLAW_LEGACY_INTERNAL_EVENT_MARKER.length,
      )
      blockEnd = nextParagraph === -1 ? next.length : nextParagraph
    } else {
      while (
        next.startsWith(
          `${OPENCLAW_LEGACY_INTERNAL_EVENT_SEPARATOR}${OPENCLAW_LEGACY_INTERNAL_EVENT_MARKER}`,
          blockEnd,
        )
      ) {
        const nextEventStart = blockEnd + OPENCLAW_LEGACY_INTERNAL_EVENT_SEPARATOR.length
        const nextEventEnd = findLegacyInternalEventEnd(next, nextEventStart)
        if (nextEventEnd == null) {
          break
        }
        blockEnd = nextEventEnd
      }
    }

    const before = next.slice(0, headerStart).trimEnd()
    const after = next.slice(blockEnd).trimStart()
    next = before && after ? `${before}\n\n${after}` : `${before}${after}`
    didStrip = true
    searchFrom = Math.max(0, before.length - 1)
  }
}

function isRuntimeContextPromptHeader(line: string): boolean {
  return (
    line === OPENCLAW_NEXT_TURN_RUNTIME_CONTEXT_HEADER ||
    line === OPENCLAW_RUNTIME_EVENT_HEADER ||
    line === OPENCLAW_LEGACY_RUNTIME_CONTEXT_HEADER
  )
}

function stripRuntimeContextPreface(text: string): { text: string; didStrip: boolean } {
  const lines = text.split(/\r?\n/)
  let didStrip = false
  const output: string[] = []

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index] ?? ""
    const nextLine = lines[index + 1] ?? ""
    if (isRuntimeContextPromptHeader(line.trim()) && nextLine.trim() === OPENCLAW_RUNTIME_CONTEXT_NOTICE) {
      didStrip = true
      index += 1
      while (index + 1 < lines.length && (lines[index + 1] ?? "").trim() === "") {
        index += 1
      }
      continue
    }
    output.push(line)
  }

  if (!didStrip) {
    return { text, didStrip: false }
  }
  return {
    text: output.join("\n").replace(/\n{3,}/g, "\n\n").trim(),
    didStrip: true,
  }
}

function isHeartbeatPromptText(text: string): boolean {
  const trimmed = text.trim()
  return (
    trimmed.startsWith("Read HEARTBEAT.md if it exists") &&
    trimmed.includes("reply HEARTBEAT_OK")
  )
}

function stripHeartbeatAck(text: string): InlineSanitizedVisibleText {
  const trimmed = text.trim()
  if (!trimmed.includes(HEARTBEAT_TOKEN)) {
    return { text, shouldSkip: false, didStrip: false }
  }

  const tokenPattern = "(?:\\*\\*|<b>|<code>)?HEARTBEAT_OK(?:\\*\\*|</b>|</code>)?"
  const stripped = trimmed
    .replace(new RegExp(`^\\s*${tokenPattern}[\\s.!:;,-]*`, "i"), "")
    .replace(new RegExp(`[\\s.!:;,-]*${tokenPattern}\\s*$`, "i"), "")
    .trim()
  const didStrip = stripped !== trimmed
  if (!didStrip) {
    return { text, shouldSkip: false, didStrip: false }
  }

  return {
    text: stripped,
    shouldSkip: !stripped || stripped.length <= 300,
    didStrip,
  }
}

export function sanitizeInlineVisibleText(raw: string | null | undefined): InlineSanitizedVisibleText {
  if (typeof raw !== "string") {
    return { text: "", shouldSkip: false, didStrip: false }
  }

  const assistantVisible = sanitizeAssistantVisibleTextWithOptions(raw, { trim: "none" })
  const assistantDidStrip = assistantVisible !== raw
  if (assistantDidStrip && !assistantVisible.trim()) {
    return { text: "", shouldSkip: true, didStrip: true }
  }

  const heartbeat = stripHeartbeatAck(assistantVisible)
  if (heartbeat.shouldSkip) {
    return heartbeat
  }

  const delimited = stripDelimitedRuntimeContext(heartbeat.text)
  const legacy = stripLegacyInternalRuntimeContext(delimited.text)
  const preface = stripRuntimeContextPreface(legacy.text)
  const didStrip =
    assistantDidStrip || heartbeat.didStrip || delimited.didStrip || legacy.didStrip || preface.didStrip
  const next = preface.text.trim()

  if (!didStrip) {
    return { text: heartbeat.text, shouldSkip: false, didStrip: false }
  }
  if (!next || isHeartbeatPromptText(next)) {
    return { text: "", shouldSkip: true, didStrip: true }
  }
  return { text: next, shouldSkip: false, didStrip: true }
}

export function sanitizeInlineVisibleLabel(raw: string | null | undefined): string | null {
  const sanitized = sanitizeInlineVisibleText(raw)
  if (sanitized.shouldSkip) return null
  const text = sanitized.text.trim()
  return text || null
}

export function sanitizeInlineActionLabel(raw: string | null | undefined): string | null {
  const text = sanitizeInlineVisibleLabel(raw)
  if (!text) return null
  if (text.length <= INLINE_ACTION_LABEL_MAX_LENGTH) return text
  return `${text.slice(0, INLINE_ACTION_LABEL_MAX_LENGTH - 3).trimEnd()}...`
}

export function sanitizeInlineActionCallbackData(raw: string | null | undefined): string | null {
  const text = raw?.trim()
  if (!text) return null
  if (utf8Encoder.encode(text).length > INLINE_ACTION_CALLBACK_DATA_MAX_BYTES) return null
  return text
}

export function sanitizeInlineActionCopyText(raw: string | null | undefined): string | null {
  const text = raw?.trim()
  if (!text) return null
  if (text.length > INLINE_ACTION_COPY_TEXT_MAX_LENGTH) return null
  return text
}
