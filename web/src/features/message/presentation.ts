/**
 * Data a row receives ready-made, prepared above the list so rendering a row
 * does no store read and no date or name formatting. Each helper caches by the
 * immutable input it is given (rows keep their identity while unchanged), so
 * calling them from a view model's computed on every update is cheap and
 * returns identical objects, which keeps memoized rows from re-rendering.
 */

import type { MessageRow, UserRow } from "@inline/core-protocol"
import type { MessageID, UserID } from "@inline/ids"
import { previewText, type TimeFormatter, userAvatarSeed, userDisplayName, userShortName } from "@inline/chat-ui"
import { avatarStyle } from "@inline/ui"

// ---------------------------------------------------------------------------
// Sender

export type SenderPresentation = {
  readonly userId: UserID
  /** The name over a run of messages: first name, else username, else "User" (Mac `shortDisplayName`). */
  readonly name: string
  /** Full name, for the avatar's accessible name and initials. */
  readonly fullName: string
  /** Avatar seed (Apple clients' rule); drives the avatar color. */
  readonly seed: string
  /** The sender's color for the name and reply bar: the avatar palette color. */
  readonly color: string
  readonly photoUrl?: string
}

const senders = new WeakMap<UserRow, SenderPresentation>()

/** The sender presentation for a user row, cached per row object. */
export const presentSender = (user: UserRow): SenderPresentation => {
  const cached = senders.get(user)
  if (cached) return cached
  const seed = userAvatarSeed(user)
  const result: SenderPresentation = {
    userId: user.id,
    name: userShortName(user),
    fullName: userDisplayName(user),
    seed,
    color: avatarStyle(seed).background,
    ...(user.photoUrl ? { photoUrl: user.photoUrl } : {}),
  }
  senders.set(user, result)
  return result
}

// ---------------------------------------------------------------------------
// Reply reference

export type ReplyPresentation = {
  readonly messageId: MessageID
  /** Undefined while the replied-to message is not loaded. */
  readonly senderName?: string
  readonly color?: string
  /** One line of the replied-to text, or a fallback. */
  readonly text: string
  /** The replied-to message is not available (not loaded or deleted). */
  readonly missing: boolean
}

const replies = new WeakMap<MessageRow, { sender: SenderPresentation | undefined; value: ReplyPresentation }>()
const missingReplies = new Map<MessageID, ReplyPresentation>()

const REPLY_PREVIEW_GRAPHEMES = 120

/**
 * The reply line for a message that replies to `messageId`. Pass the replied
 * row when it is loaded and its sender when known. Cached per replied row.
 */
export const presentReply = (
  messageId: MessageID,
  replied: MessageRow | undefined,
  sender: SenderPresentation | undefined,
): ReplyPresentation => {
  if (!replied) {
    let missing = missingReplies.get(messageId)
    if (!missing) {
      missing = { messageId, text: "Original message", missing: true }
      if (missingReplies.size > 512) missingReplies.clear()
      missingReplies.set(messageId, missing)
    }
    return missing
  }
  const cached = replies.get(replied)
  if (cached && cached.sender === sender) return cached.value
  const value: ReplyPresentation = {
    messageId,
    ...(sender ? { senderName: sender.name, color: sender.color } : {}),
    text: previewText(replied.text, {
      maxGraphemes: REPLY_PREVIEW_GRAPHEMES,
      fallback: replied.hasUnsupportedContent ? "Message" : "Empty message",
    }),
    missing: false,
  }
  replies.set(replied, { sender, value })
  return value
}

// ---------------------------------------------------------------------------
// Times

export type MessageTimes = {
  /** "3:07 PM" for seconds since the epoch. */
  time(seconds: number): string
  /** "Nov 17, 2026, 3:07 PM", for the tooltip. */
  tooltip(seconds: number): string
}

/**
 * Message times from one formatter, cached per minute. Create one per
 * formatter (per locale or time zone change), above the list.
 */
export const createMessageTimes = (formatter: TimeFormatter, limit = 4096): MessageTimes => {
  const times = new Map<number, string>()
  const tooltips = new Map<number, string>()
  const cached = (cache: Map<number, string>, seconds: number, format: (seconds: number) => string): string => {
    const minute = Math.floor(seconds / 60)
    const hit = cache.get(minute)
    if (hit !== undefined) return hit
    const value = format(minute * 60)
    if (cache.size >= limit) cache.clear()
    cache.set(minute, value)
    return value
  }
  return {
    time: (seconds) => cached(times, seconds, formatter.time),
    tooltip: (seconds) => cached(tooltips, seconds, formatter.tooltip),
  }
}
