const HEARTBEAT_TOKEN = "HEARTBEAT_OK"
const OPENCLAW_RUNTIME_CONTEXT_NOTICE =
  "This context is runtime-generated, not user-authored. Keep internal details private."
const OPENCLAW_NEXT_TURN_RUNTIME_CONTEXT_HEADER =
  "OpenClaw runtime context for the immediately preceding user message."
const OPENCLAW_RUNTIME_EVENT_HEADER = "OpenClaw runtime event."
const OPENCLAW_LEGACY_RUNTIME_CONTEXT_HEADER = "OpenClaw runtime context (internal):"
const OPENCLAW_INTERNAL_CONTEXT_BEGIN = "<<<BEGIN_OPENCLAW_INTERNAL_CONTEXT>>>"
const OPENCLAW_INTERNAL_CONTEXT_END = "<<<END_OPENCLAW_INTERNAL_CONTEXT>>>"

export type InlineSanitizedVisibleText = {
  text: string
  shouldSkip: boolean
  didStrip: boolean
}

function stripDelimitedRuntimeContext(text: string): { text: string; didStrip: boolean } {
  let next = text
  let didStrip = false
  for (;;) {
    const start = next.indexOf(OPENCLAW_INTERNAL_CONTEXT_BEGIN)
    if (start < 0) return { text: next, didStrip }
    const end = next.indexOf(
      OPENCLAW_INTERNAL_CONTEXT_END,
      start + OPENCLAW_INTERNAL_CONTEXT_BEGIN.length,
    )
    const before = next.slice(0, start).trimEnd()
    if (end < 0) return { text: before, didStrip: true }
    const after = next.slice(end + OPENCLAW_INTERNAL_CONTEXT_END.length).trimStart()
    next = before && after ? `${before}\n\n${after}` : `${before}${after}`
    didStrip = true
  }
}

function stripRuntimeContextPreface(text: string): { text: string; didStrip: boolean } {
  const lines = text.split(/\r?\n/)
  const first = lines[0]?.trim()
  const second = lines[1]?.trim()
  const hasPreface =
    (first === OPENCLAW_NEXT_TURN_RUNTIME_CONTEXT_HEADER ||
      first === OPENCLAW_RUNTIME_EVENT_HEADER ||
      first === OPENCLAW_LEGACY_RUNTIME_CONTEXT_HEADER) &&
    second === OPENCLAW_RUNTIME_CONTEXT_NOTICE
  if (!hasPreface) {
    return { text, didStrip: false }
  }

  let index = 2
  while (index < lines.length && !lines[index]?.trim()) {
    index += 1
  }
  return {
    text: lines.slice(index).join("\n").trim(),
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

  const heartbeat = stripHeartbeatAck(raw)
  if (heartbeat.shouldSkip) {
    return heartbeat
  }

  const delimited = stripDelimitedRuntimeContext(heartbeat.text)
  const preface = stripRuntimeContextPreface(delimited.text)
  const didStrip = heartbeat.didStrip || delimited.didStrip || preface.didStrip
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
