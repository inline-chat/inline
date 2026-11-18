/**
 * The small lines around a message's content: the forward header, "Sent via"
 * and the reply thread summary. Mac wording (`MessageView.swift` forward
 * header, `InlineKit/Models/MessageViaPresentation.swift`,
 * `ReplyThreadSummaryView.swift`). Names are resolved by the caller.
 */

import type { ForwardHeader, MessageRow, RepliesSummary, ViaInfo } from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"

// ---------------------------------------------------------------------------
// Forward

export type ForwardHeaderModel = {
  /** "Forwarded from: Ada", or "Forwarded from a private chat" when the source is not known here. */
  readonly text: string
  /** Where a click goes; undefined when there is nowhere to go. */
  readonly target:
    | { readonly kind: "user"; readonly userId: UserID; readonly messageId: MessageID | undefined }
    | { readonly kind: "chat"; readonly chatId: ChatID; readonly messageId: MessageID | undefined }
    | undefined
}

export type ForwardNames = {
  /**
   * The source's title: for a chat source, the chat title ("Untitled" is used
   * when it has none); for a user source, the original sender's short name.
   * Undefined when the source is not known locally.
   */
  readonly title?: string
  /** The viewer, so a forward of their own message targets the peer instead. */
  readonly me?: UserID
}

export const forwardHeaderModel = (forward: ForwardHeader, names: ForwardNames = {}): ForwardHeaderModel => {
  const peer = forward.fromPeer
  const title = names.title?.trim()
  const text = title ? `Forwarded from: ${title}` : "Forwarded from a private chat"
  if (peer?.kind === "chat") return { text, target: { kind: "chat", chatId: peer.chatId, messageId: forward.fromMessageId } }
  const sender = forward.fromUserId
  const user = sender && sender !== names.me ? sender : peer?.kind === "user" ? peer.userId : sender
  return { text, target: user ? { kind: "user", userId: user, messageId: forward.fromMessageId } : undefined }
}

// ---------------------------------------------------------------------------
// Via

export type ViaModel = {
  /** "Sent via Claude Code". */
  readonly label: string
  /** "Ada sent this using Claude Code, an AI agent." */
  readonly tooltip: string
  readonly name: string
  /** The bot's avatar, or the agent's badge (`app` is the known agent ID). */
  readonly badge: { readonly kind: "bot"; readonly userId: UserID } | { readonly kind: "app"; readonly app: string }
}

/**
 * `botName` is the bot's current short name when known (it wins over the
 * name the message was sent with); `sender` defaults to "The sender".
 */
export const viaModel = (via: ViaInfo, names: { botName?: string; sender?: string } = {}): ViaModel => {
  const sender = names.sender?.trim() || "The sender"
  if (via.kind === "bot") {
    const name = names.botName?.trim() || via.name?.trim() || "a bot"
    return {
      label: `Sent via ${name}`,
      tooltip: `${sender} sent this using their bot ${name}.`,
      name,
      badge: { kind: "bot", userId: via.botUserId },
    }
  }
  const app = via.app.trim() || "agent"
  const sentName = via.name?.trim()
  const unnamed = app === "agent" && !sentName
  const name = unnamed ? "an AI agent" : (sentName ?? app)
  return {
    label: `Sent via ${name}`,
    tooltip: unnamed ? `${sender} sent this using an AI agent.` : `${sender} sent this using ${name}, an AI agent.`,
    name,
    badge: { kind: "app", app },
  }
}

/** Whether two messages may group: same `via` (both absent counts) and neither is a service row. */
export const sameVia = (a: Pick<MessageRow, "via">, b: Pick<MessageRow, "via">): boolean => {
  if (!a.via || !b.via) return !a.via && !b.via
  if (a.via.kind === "bot" && b.via.kind === "bot") return a.via.botUserId === b.via.botUserId
  if (a.via.kind === "app" && b.via.kind === "app") return a.via.app === b.via.app
  return false
}

// ---------------------------------------------------------------------------
// Reply thread summary

export type RepliesSummaryModel = {
  readonly key: string
  readonly chatId: ChatID
  readonly kind: RepliesSummary["kind"]
  readonly title: string | undefined
  /** "3 replies", "Subthread · 1 message". */
  readonly label: string
  readonly hasUnread: boolean
  /** Up to 3 avatars, newest first. */
  readonly avatars: readonly UserID[]
  /** 30, or 46 with a title. */
  readonly height: number
}

const plural = (count: number, one: string, many: string, locale?: string | readonly string[]): string => {
  let formatted: string
  try {
    formatted = new Intl.NumberFormat(locale as string | string[] | undefined).format(count)
  } catch {
    formatted = String(count)
  }
  return `${formatted} ${count === 1 ? one : many}`
}

/** The summary under a message, or undefined when the Mac would hide it. */
export const repliesSummaryModel = (
  replies: RepliesSummary | undefined,
  locale?: string | readonly string[],
): RepliesSummaryModel | undefined => {
  if (!replies) return undefined
  const title = replies.title?.trim() || undefined
  if (replies.kind === "subthread" && !title) return undefined
  if (replies.kind === "reply" && replies.count <= 0) return undefined
  const label =
    replies.kind === "subthread"
      ? `Subthread · ${plural(replies.count, "message", "messages", locale)}`
      : plural(replies.count, "reply", "replies", locale)
  return {
    key: `replies:${replies.chatId}`,
    chatId: replies.chatId,
    kind: replies.kind,
    title,
    label,
    hasUnread: replies.hasUnread,
    avatars: replies.recentUserIds.slice(0, 3),
    height: title ? 46 : 30,
  }
}
