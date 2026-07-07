import type { InlineIdLike } from "../ids.js"

export const INLINE_FOLLOW_MODE_MENTION_FRESH_LAST_MESSAGE_ID_LIMIT = 50

export type InlineMentionGateIdLike = InlineIdLike | string

export type InlineFollowModeMentionGateChat = {
  parentChatId?: InlineMentionGateIdLike | null
  parentMessageId?: InlineMentionGateIdLike | null
  lastMsgId?: InlineMentionGateIdLike | null
}

export function isInlineReplyThreadForMentionGate(chat: InlineFollowModeMentionGateChat): boolean {
  return parsePositiveInteger(chat.parentMessageId) != null
}

export function isInlineFreshThreadForMentionGate(
  lastMsgId: InlineMentionGateIdLike | null | undefined,
  limit = INLINE_FOLLOW_MODE_MENTION_FRESH_LAST_MESSAGE_ID_LIMIT,
): boolean {
  const normalized = parsePositiveInteger(lastMsgId)
  return normalized != null && normalized < BigInt(limit)
}

export function isInlineFollowModeMentionGateEligible(chat: InlineFollowModeMentionGateChat): boolean {
  if (isInlineReplyThreadForMentionGate(chat)) {
    return true
  }
  return isInlineFreshThreadForMentionGate(chat.lastMsgId)
}

function parsePositiveInteger(value: InlineMentionGateIdLike | null | undefined): bigint | null {
  if (value == null) return null
  if (typeof value === "bigint") return value > 0n ? value : null
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || value <= 0) return null
    return BigInt(value)
  }

  const text = value.trim()
  if (!/^[1-9]\d*$/.test(text)) return null
  return BigInt(text)
}
