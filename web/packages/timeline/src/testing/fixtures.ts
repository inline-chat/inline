/**
 * Small builders for message rows and items, shared by this package's tests.
 * Not exported from the package.
 */

import { chatId, messageId, userId, type MessageID, type UserID } from "@inline/ids"
import { receivedMessageRowId, type MessageRow } from "@inline/core-protocol"
import { timelineItems, type TimelineItem } from "../items"

export const CHAT = chatId(7)
export const ME = userId(1)
export const ALICE = userId(2)
export const BOB = userId(3)

/** 2026-11-17 12:00:00 UTC, in seconds. */
export const NOON = Date.UTC(2026, 10, 17, 12, 0, 0) / 1000

export const msg = (
  id: number,
  options: { from?: UserID; date?: number; out?: boolean; text?: string } = {},
): MessageRow => {
  const from = options.from ?? ALICE
  return {
    kind: "message",
    id: receivedMessageRowId(CHAT, messageId(id)),
    chatId: CHAT,
    messageId: messageId(id),
    fromId: from,
    out: options.out ?? from === ME,
    date: options.date ?? NOON + id * 600,
    text: options.text ?? `message ${id}`,
    state: "sent",
  }
}

export const mid = (id: number): MessageID => messageId(id)

/** Rows `from..to` inclusive, alternating senders every message so nothing groups. */
export const history = (from: number, to: number, options: { date?: (id: number) => number } = {}) => {
  const rows: MessageRow[] = []
  for (let id = from; id <= to; id++)
    rows.push(msg(id, { from: id % 2 === 0 ? ALICE : BOB, ...(options.date ? { date: options.date(id) } : {}) }))
  return rows
}

export const itemsOf = (
  rows: readonly MessageRow[],
  unread?: { boundary: MessageID; reachesHistoryStart?: boolean },
): TimelineItem[] =>
  timelineItems({ rows, viewerId: ME, timeZone: "UTC", ...(unread ? { unread } : {}) }).items
