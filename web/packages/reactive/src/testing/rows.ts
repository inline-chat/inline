/** Synthetic rows for tests and labs. No chat semantics beyond the row shapes. */

import type { ChatID, MessageID, UserID } from "@inline/ids"
import { optimisticMessageRow, receivedMessageRowId, type Intent, type MessageRow } from "@inline/core-protocol"

export const chatId = (n: number | string) => String(n) as ChatID
export const messageId = (n: number | string) => String(n) as MessageID
export const userId = (n: number | string) => String(n) as UserID

export const message = (chat: number, id: number, text = `message ${id}`, extra: Partial<MessageRow> = {}): MessageRow => ({
  kind: "message",
  id: receivedMessageRowId(chatId(chat), messageId(id)),
  chatId: chatId(chat),
  messageId: messageId(id),
  fromId: userId(1),
  out: false,
  date: 1_700_000_000 + id,
  text,
  state: "sent",
  ...extra,
})

export const sendText = (chat: number, clientKey: string, text: string): Extract<Intent, { kind: "sendText" }> => ({
  kind: "sendText",
  chatId: chatId(chat),
  clientKey,
  text,
})

export const echoRow = (intent: Extract<Intent, { kind: "sendText" }>, date = 1_800_000_000): MessageRow =>
  optimisticMessageRow(intent, userId(1), date)
