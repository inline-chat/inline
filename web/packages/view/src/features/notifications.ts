/**
 * Glue between the rows and the platform's notification and badge policies.
 * Pure: the app gathers the inputs (the core's `newMessages` feed ships each
 * message with its chat and dialog rows), calls `decideMessageNotification`
 * from `@inline/platform` with the facts, and shows what it says.
 */

import type { ChatRow, DialogRow, MessageRow, RowKey } from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import type { ChatNotificationMode, GlobalNotificationMode, MessageNotificationFacts } from "@inline/platform"
import { compareMessageIds, peerUserIdOf } from "./helpers"

/** Keys present in `next` but not in `previous`, in `next`'s order: the rows that just arrived. */
export const addedKeys = (previous: readonly RowKey[], next: readonly RowKey[]): RowKey[] => {
  if (previous.length === 0) return [...next]
  const seen = new Set(previous)
  return next.filter((key) => !seen.has(key))
}

export type NotificationFactsInput = {
  readonly message: MessageRow
  readonly me: UserID
  /** First time this row reached this context (from `addedKeys`), not an edit or a resync. */
  readonly newlyInserted: boolean
  readonly chat: ChatRow | undefined
  readonly dialog: DialogRow | undefined
  /** `isViewingConversation` from `@inline/platform`, for this message's chat. */
  readonly viewingConversation: boolean
  readonly nowMs: number
  /** Overrides the chat's mode. Default: the dialog's `notificationMode`, else `global`. */
  readonly chatMode?: ChatNotificationMode
  /** The account's mode. Default `all`. TODO(contract): account settings come with the `userSettings` query. */
  readonly globalMode?: GlobalNotificationMode
  /** The author of the replied-to message, when its row is at hand. */
  readonly repliedToAuthor?: UserID
  readonly soundEnabled?: boolean
}

/**
 * Whether a message is above the dialog's read frontier. Without a dialog or
 * a server ID the message counts as unread (it just arrived).
 */
export const isUnread = (message: MessageRow, dialog: DialogRow | undefined): boolean => {
  if (!message.messageId || !dialog?.readMaxId) return true
  return compareMessageIds(message.messageId, dialog.readMaxId) > 0
}

/**
 * The facts `decideMessageNotification` needs, from the rows: a mention is
 * the server's `mentioned` flag (direct or through a group) or a mention
 * entity of the user; `silent` is the sender's silent send; the chat's mode
 * is the dialog's `notificationMode` unless `chatMode` overrides it.
 */
export const messageNotificationFacts = (input: NotificationFactsInput): MessageNotificationFacts => {
  const { message, me } = input
  const mentionsMe =
    message.mentioned === true ||
    (message.entities ?? []).some((entity) => entity.type === "mention" && entity.userId === me)
  return {
    outgoing: message.out || message.fromId === me,
    newlyInserted: input.newlyInserted,
    unread: isUnread(message, input.dialog),
    ...(message.silent === true ? { silentSend: true } : {}),
    dateSeconds: message.date,
    nowMs: input.nowMs,
    viewingConversation: input.viewingConversation,
    chatMode: input.chatMode ?? input.dialog?.notificationMode ?? "global",
    globalMode: input.globalMode ?? "all",
    directMessage: peerUserIdOf(input.dialog, input.chat) !== undefined,
    mentionsMe,
    ...(input.repliedToAuthor !== undefined ? { repliesToMe: input.repliedToAuthor === me } : {}),
    ...(input.soundEnabled !== undefined ? { soundEnabled: input.soundEnabled } : {}),
  }
}

/** What a notification click carries (`messageNotificationTag` data), as the workspace opens it. */
export const notificationDestination = (chatId: ChatID, messageId: MessageID | undefined) =>
  messageId ? ({ kind: "message", chatId, messageId } as const) : ({ kind: "chat", chatId } as const)
