import { isReasoningReplyPayload } from "openclaw/plugin-sdk/reply-payload"
import { findCodeRegions, isInsideCode, stripReasoningTagsFromText } from "openclaw/plugin-sdk/text-chunking"
import { normalizeLowercaseStringOrEmpty } from "openclaw/plugin-sdk/string-coerce-runtime"
import { sanitizeInlineVisibleText } from "./outbound-sanitize.js"
import type { InlineReplyPayload } from "./monitor-shared.js"

const REASONING_MESSAGE_PREFIX = "Reasoning:\n"
const REASONING_TAG_PREFIXES = [
  "<think",
  "<thinking",
  "<thought",
  "<antthinking",
  "</think",
  "</thinking",
  "</thought",
  "</antthinking",
]
const THINKING_TAG_RE = /<\s*(\/?)\s*(?:think(?:ing)?|thought|antthinking)\b[^<>]*>/gi

export function resolveInlinePayloadMediaUrls(payload: InlineReplyPayload): string[] {
  const urls = payload.mediaUrls?.length
    ? payload.mediaUrls
    : payload.mediaUrl
      ? [payload.mediaUrl]
      : []
  return Array.from(new Set(urls.map((url) => url.trim()).filter(Boolean)))
}

function isPartialReasoningTagPrefix(text: string): boolean {
  const trimmed = normalizeLowercaseStringOrEmpty(text.trimStart())
  if (!trimmed.startsWith("<")) return false
  if (trimmed.includes(">")) return false
  return REASONING_TAG_PREFIXES.some((prefix) => prefix.startsWith(trimmed))
}

type InlineReasoningSplit = {
  reasoningText?: string
  answerText?: string
}

function formatInlineReasoningMessage(text: string): string {
  const trimmed = text.trim()
  if (!trimmed) return ""
  const italicLines = trimmed
    .split("\n")
    .map((line) => (line ? `_${line}_` : line))
    .join("\n")
  return `${REASONING_MESSAGE_PREFIX}${italicLines}`
}

function extractInlineThinkingFromTaggedStreamOutsideCode(text: string): string {
  if (!text) return ""
  const codeRegions = findCodeRegions(text)
  let result = ""
  let lastIndex = 0
  let inThinking = false
  THINKING_TAG_RE.lastIndex = 0
  for (const match of text.matchAll(THINKING_TAG_RE)) {
    const idx = match.index ?? 0
    if (isInsideCode(idx, codeRegions)) continue
    if (inThinking) {
      result += text.slice(lastIndex, idx)
    }
    const isClose = match[1] === "/"
    inThinking = !isClose
    lastIndex = idx + match[0].length
  }
  if (inThinking) {
    result += text.slice(lastIndex)
  }
  return result.trim()
}

function splitInlineReasoningText(text?: string, isReasoning?: boolean): InlineReasoningSplit {
  if (typeof text !== "string") return {}

  const trimmed = text.trim()
  if (isPartialReasoningTagPrefix(trimmed)) {
    return {}
  }
  if (
    trimmed.startsWith(REASONING_MESSAGE_PREFIX) &&
    trimmed.length > REASONING_MESSAGE_PREFIX.length
  ) {
    return { reasoningText: trimmed }
  }

  const taggedReasoning = extractInlineThinkingFromTaggedStreamOutsideCode(text)
  const strippedAnswer = stripReasoningTagsFromText(text, { mode: "strict", trim: "both" })

  if (isReasoning === true) {
    return {
      reasoningText: formatInlineReasoningMessage(
        taggedReasoning || strippedAnswer || text,
      ),
    }
  }
  if (!taggedReasoning && strippedAnswer === text) {
    return { answerText: text }
  }
  const reasoningText = taggedReasoning
    ? formatInlineReasoningMessage(taggedReasoning)
    : undefined
  return {
    ...(reasoningText ? { reasoningText } : {}),
    ...(strippedAnswer ? { answerText: strippedAnswer } : {}),
  }
}

export function resolveInlineChatVisibleReplyPayload<T extends InlineReplyPayload>(payload: T): T | null {
  const mediaUrls = resolveInlinePayloadMediaUrls(payload)
  if (isReasoningReplyPayload({
    ...(typeof payload.text === "string" ? { text: payload.text } : {}),
    ...(payload.isReasoning !== undefined ? { isReasoning: payload.isReasoning } : {}),
  })) {
    return mediaUrls.length > 0 ? { ...payload, text: undefined } : null
  }

  if (typeof payload.text !== "string") {
    return payload
  }

  const internal = sanitizeInlineVisibleText(payload.text)
  if (internal.shouldSkip) {
    return mediaUrls.length > 0 ? { ...payload, text: undefined } : null
  }
  if (isPartialReasoningTagPrefix(internal.text.trim())) {
    return mediaUrls.length > 0 ? { ...payload, text: undefined } : null
  }

  const split = splitInlineReasoningText(internal.text, payload.isReasoning)
  if (split.answerText !== undefined) {
    if (split.answerText === payload.text) {
      return payload
    }
    return {
      ...payload,
      text: split.answerText || undefined,
    }
  }
  if (!split.reasoningText) {
    return payload
  }
  return mediaUrls.length > 0 ? { ...payload, text: undefined } : null
}
