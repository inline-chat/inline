import type { QueryDescriptor } from "@inline/core-protocol"
import { isAttachmentId, type MediaRef } from "@inline/core-protocol"
import { parseInlineId } from "@inline/ids"
import { CHAT_MEDIA_FILTERS } from "./chat-media"

/** IDs travel as branded, canonical decimal strings. */
export const isPositiveId = (value: unknown): value is string =>
  typeof value === "string" && parseInlineId(value, { positive: true }) === value

const positive = isPositiveId

const CHAT_MEDIA_FILTER_SET = new Set<string>(CHAT_MEDIA_FILTERS)

/**
 * Whether a descriptor that arrived over the protocol is well formed. The core
 * never trusts the shape of a command; a malformed query stays empty.
 */
export const isValidQuery = (query: unknown): query is QueryDescriptor => {
  if (query == null || typeof query !== "object") return false
  const candidate = query as Record<string, unknown>
  switch (candidate.kind) {
    case "core":
    case "me":
    case "newMessages":
      return true
    case "sidebar":
      return (
        (candidate.mode === "inbox" || candidate.mode === "all" || candidate.mode === "archived") &&
        (candidate.spaceId == null || positive(candidate.spaceId))
      )
    case "chatWindow": {
      if (!positive(candidate.chatId)) return false
      const anchor = candidate.anchor
      if (anchor === "latest" || anchor === "unread") return true
      return (
        anchor != null &&
        typeof anchor === "object" &&
        positive((anchor as Record<string, unknown>).around)
      )
    }
    case "chat":
    case "draft":
      return positive(candidate.chatId)
    case "user":
      return positive(candidate.userId)
    case "chatParticipants":
      return positive(candidate.chatId)
    case "spaceMembers":
    case "userGroups":
      return positive(candidate.spaceId)
    case "spaces":
    case "userSettings":
    case "dialogFolders":
      return true
    case "composeActions":
      return candidate.chatId == null || positive(candidate.chatId)
    case "media":
      return (
        isMediaRef(candidate.media) &&
        (candidate.priority == null || candidate.priority === "visible" || candidate.priority === "opened")
      )
    case "searchMessages":
    case "findInChat":
    case "countMessages":
    case "searchServerMessages":
    case "searchUsers":
      return candidate.request != null && typeof candidate.request === "object"
    case "chatMedia":
      return positive(candidate.chatId) && CHAT_MEDIA_FILTER_SET.has(candidate.filter as string)
    default:
      return false
  }
}

/** Whether a media reference that arrived over the protocol is well formed. */
export const isMediaRef = (value: unknown): value is MediaRef => {
  if (value == null || typeof value !== "object") return false
  const ref = value as Record<string, unknown>
  if (ref.kind === "attachment") return isAttachmentId(ref.attachmentId)
  return (
    ref.kind === "message" &&
    positive(ref.chatId) &&
    positive(ref.messageId) &&
    (ref.size == null || (typeof ref.size === "string" && /^[a-z]{1,4}$/i.test(ref.size))) &&
    (ref.thumbnail == null || typeof ref.thumbnail === "boolean")
  )
}
