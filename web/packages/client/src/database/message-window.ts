import {
  compareInlineIds,
  parseInlineId,
  type MessageID,
} from "@inline/ids"
import type { Message } from "./models"

export type MessageWindowCursor = {
  date: number
  messageId: MessageID
}

export const messageWindowDate = (
  date: number | undefined,
): number => {
  if (date == null) return 0
  if (!Number.isSafeInteger(date)) {
    throw new RangeError(
      `Invalid Inline message date: ${String(date)}`,
    )
  }
  return date
}

export const messageWindowCursor = (
  message: Pick<Message, "date" | "messageId">,
): MessageWindowCursor => ({
  date: messageWindowDate(message.date),
  messageId: message.messageId,
})

export const compareMessageWindowCursors = (
  left: MessageWindowCursor,
  right: MessageWindowCursor,
): number =>
  left.date - right.date ||
  compareInlineIds(left.messageId, right.messageId)

export const compareMessagesByWindow = (
  left: Pick<Message, "date" | "messageId">,
  right: Pick<Message, "date" | "messageId">,
): number =>
  compareMessageWindowCursors(
    messageWindowCursor(left),
    messageWindowCursor(right),
  )

export const messageWindowCursorKey = (
  cursor: MessageWindowCursor,
) => `${cursor.date}:${cursor.messageId}`

export const parseMessageWindowCursor = (
  value: unknown,
): MessageWindowCursor | undefined => {
  if (!value || typeof value !== "object") return undefined
  const candidate = value as Record<string, unknown>
  if (
    !Number.isSafeInteger(candidate.date) ||
    typeof candidate.date !== "number"
  ) {
    return undefined
  }
  const parsedMessageId = parseInlineId<"message">(
    candidate.messageId,
  )
  if (!parsedMessageId) return undefined
  return {
    date: candidate.date,
    messageId: parsedMessageId,
  }
}
