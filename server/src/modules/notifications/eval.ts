import { MessageEntity_Type, type MessageEntities } from "@inline-chat/protocol/core"
import type { ProcessedMessage } from "@in/server/db/models/messages"
import { getCachedUserName, UserNamesCache } from "@in/server/modules/cache/userNames"

export type NotificationEvalResult = {
  notifyUserIds: number[]
}

/** Legacy Zen-mode checker kept as a no-op so no notification content is sent to AI. */
export const batchEvaluate = async (_input?: unknown): Promise<NotificationEvalResult> => {
  return { notifyUserIds: [] }
}

export const formatMessage = (m: ProcessedMessage): string => {
  return `<message 
id="${m.messageId}"
sentAt="${m.date.toISOString()}"
senderUserId="${m.fromId}" 
${m.replyToMsgId ? `replyToMsgId="${m.replyToMsgId}"` : ""}>
${m.photoId ? "[photo attachment]" : ""} ${m.videoId ? "[video attachment]" : ""} ${
    m.documentId ? "[document attachment]" : ""
  } ${m.voiceId ? "[voice attachment]" : ""} ${m.text ? m.text : "[empty caption]"}
  ${m.entities ? formatEntities(m.entities) : ""}
  </message>`
}

/** Useful for concise conversation history display */
export const formatMessageSimple = async (m: ProcessedMessage): Promise<string> => {
  let sender = await getCachedUserName(m.fromId)
  let senderDisplayName = sender ? UserNamesCache.getDisplayName(sender) : `User ${m.fromId}`
  let willTruncate = m.text && m.text.length > 200
  let textContent = m.text ? (willTruncate ? m.text.slice(0, 200) + "..." : m.text) : "[empty caption]"
  return `[messageId: ${m.messageId}] ${senderDisplayName} (${relativeTimeFromNow(m.date)}): ${textContent}`
}

export const formatEntities = (entities: MessageEntities): string => {
  let content = entities.entities
    .map(
      (e) =>
        `<entity type="${MessageEntity_Type[e.type]}" offset="${e.offset}" length="${e.length}" ${
          "userId" in e.entity ? `userId="${e.entity.userId}"` : ""
        } />`,
    )
    .join("\n")

  return `<entities>${content}</entities>`
}

/**
 * Returns a relative time label such as:
 *   “just now”, “3 m ago”, “2 h ago”, “5 d ago”, “1 y ago”
 */
export const relativeTimeFromNow = (date: Date): string => {
  const secs = Math.floor((Date.now() - date.getTime()) / 1000)

  const MIN = 60
  const HOUR = 60 * MIN
  const DAY = 24 * HOUR
  const WEEK = 7 * DAY
  const YEAR = 365 * DAY

  switch (true) {
    case secs < 10:
      return "just now"
    case secs < MIN:
      return `${secs}s ago`
    case secs < HOUR:
      return `${Math.floor(secs / MIN)}m ago`
    case secs < DAY:
      return `${Math.floor(secs / HOUR)}h ago`
    case secs < WEEK:
      return `${Math.floor(secs / DAY)}d ago`
    case secs < YEAR:
      return `${Math.floor(secs / WEEK)}w ago`
    default:
      return `${Math.floor(secs / YEAR)}y ago`
  }
}
