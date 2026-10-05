import type { Chat, Message, User } from "@inline/client/core"
import type { UserID } from "@inline/ids"

export const nameForUser = (user: User | undefined): string =>
  [user?.firstName, user?.lastName].filter(Boolean).join(" ").trim() ||
  user?.username ||
  "Unknown person"

export const titleForChat = (
  chat: Chat,
  users: ReadonlyMap<UserID, User> | readonly User[],
): string => {
  if (chat.peerUserId != null) {
    const user = Array.isArray(users)
      ? users.find((candidate) => candidate.id === chat.peerUserId)
      : (users as ReadonlyMap<UserID, User>).get(chat.peerUserId)
    return nameForUser(user)
  }
  return chat.title?.trim() || (chat.number != null ? `Thread ${chat.number}` : "Untitled thread")
}

export type ConversationRow =
  | { kind: "day"; key: string; date: number }
  | {
      kind: "message"
      key: string
      message: Message
      groupedWithPrevious: boolean
      groupedWithNext: boolean
    }

export const dayKey = (seconds: number): string => {
  const date = new Date(seconds * 1000)
  return `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`
}

const grouped = (previous: Message | undefined, next: Message | undefined) => {
  if (
    !previous ||
    !next ||
    previous.serviceMessage ||
    next.serviceMessage ||
    previous.fromId !== next.fromId ||
    previous.chatId !== next.chatId ||
    previous.out !== next.out
  )
    return false
  if (
    previous.date == null ||
    next.date == null ||
    next.replyToMsgId != null ||
    previous.fwdFrom ||
    next.fwdFrom
  )
    return false
  const elapsed = next.date - previous.date
  return elapsed >= 0 && elapsed <= 5 * 60 && dayKey(previous.date) === dayKey(next.date)
}

/** Pure, bounded render projection with Noor's day boundaries and sender runs. */
export const projectConversation = (messages: readonly Message[]): ConversationRow[] => {
  const rows: ConversationRow[] = []
  let previousDay: string | undefined
  messages.forEach((message, index) => {
    if (message.date != null) {
      const day = dayKey(message.date)
      if (day !== previousDay)
        rows.push({ kind: "day", key: `day:${day}:${message.id}`, date: message.date })
      previousDay = day
    }
    rows.push({
      kind: "message",
      key: message.id,
      message,
      groupedWithPrevious: grouped(messages[index - 1], message),
      groupedWithNext: grouped(message, messages[index + 1]),
    })
  })
  return rows
}
