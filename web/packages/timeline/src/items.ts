/**
 * Timeline items: what the message list renders, computed from the window's
 * ordered message rows. Pure. Rules from the Mac client:
 *
 * - `apple/InlineMac/Views/MessageList/ChatRowListViewModel.swift` (`makeRows`):
 *   a day separator before the first message and wherever the calendar day
 *   changes; the unread line goes before the day separator when both apply,
 *   so opening with the line at the top still shows the date.
 * - `MessageListAppKit.swift` (`canGroup`, `isFirstInGroup`, `isLastInGroup`):
 *   grouping is decided between adjacent messages, ignoring separators: same
 *   sender, at most 300 s apart, same calendar day (and same `via`, neither a
 *   service message: see `breaksGroup`).
 * - `apple/InlineKit/.../ChatUnreadOpening.swift` (`firstUnreadMessageId`):
 *   the unread line sits above the first message after the read boundary that
 *   is not the viewer's own, and only when the window reaches the boundary.
 */

import type { MessageID, UserID } from "@inline/ids"
import type { MessageRow } from "@inline/core-protocol"
import { GROUP_MAX_GAP_SECONDS } from "./constants"

export type MessageItem = {
  kind: "message"
  key: string
  row: MessageRow
  /** First message of a sender run (shows the sender). */
  firstInGroup: boolean
  /** Last message of a sender run. */
  lastInGroup: boolean
  /** Calendar day in the item's time zone, `YYYY-MM-DD`. */
  dayKey: string
}

export type DaySeparatorItem = {
  kind: "day"
  key: string
  /** Calendar day in the item's time zone, `YYYY-MM-DD`. */
  dayKey: string
  /** Seconds since the epoch of the first message of that day in the window, for the label. */
  date: number
}

export type UnreadLineItem = { kind: "unread"; key: typeof UNREAD_LINE_KEY }

export type TimelineItem = MessageItem | DaySeparatorItem | UnreadLineItem

export const UNREAD_LINE_KEY = "unread"

/** Stable across the send acknowledgement: `MessageRowId` keeps its identity. */
export const messageItemKey = (row: Pick<MessageRow, "id">): string => `m:${row.id}`
export const daySeparatorKey = (dayKey: string): string => `d:${dayKey}`

export type UnreadInput = {
  /** The read boundary captured when the chat opened ("0": nothing read). */
  boundary: MessageID
  /** True when no older message exists before the window. */
  reachesHistoryStart?: boolean
  /**
   * The message the line was placed above earlier in this visit. Pass back the
   * `unreadLineAbove` of a previous result so the line never moves.
   */
  lineAbove?: MessageID
}

export type TimelineItemsInput = {
  /** The window's rows, oldest first. */
  rows: readonly MessageRow[]
  viewerId: UserID
  /** IANA time zone for calendar days, for example "Europe/Berlin". */
  timeZone: string
  unread?: UnreadInput
  /**
   * Hook for grouping rules the contract cannot express yet: return true when
   * two adjacent messages that otherwise group must not (a different `via`
   * signature, a service message). Mac: `canGroup` checks
   * `isServiceMessage` and `via`. TODO(contract): `MessageRow` has neither.
   */
  breaksGroup?: (earlier: MessageRow, later: MessageRow) => boolean
}

export type TimelineItemsResult = {
  items: TimelineItem[]
  /** The message the unread line sits above, to pass back as `unread.lineAbove`. */
  unreadLineAbove: MessageID | undefined
}

// ---------------------------------------------------------------------------
// Calendar days

const dayFormatters = new Map<string, Intl.DateTimeFormat>()
const dayCaches = new Map<string, Map<number, string>>()
const DAY_CACHE_LIMIT = 4096
/**
 * Every current UTC offset and every transition instant is a multiple of 15
 * minutes, so all seconds inside one 15-minute UTC bucket share a local date.
 */
const DAY_BUCKET_SECONDS = 900

/** The calendar day of `seconds` since the epoch in `timeZone`, as `YYYY-MM-DD`. */
export const dayKeyOf = (seconds: number, timeZone: string): string => {
  let cache = dayCaches.get(timeZone)
  if (!cache) {
    cache = new Map()
    dayCaches.set(timeZone, cache)
  }
  const bucket = Math.floor(seconds / DAY_BUCKET_SECONDS)
  const cached = cache.get(bucket)
  if (cached !== undefined) return cached

  let format = dayFormatters.get(timeZone)
  if (!format) {
    format = new Intl.DateTimeFormat("en-US", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    })
    dayFormatters.set(timeZone, format)
  }
  let year = ""
  let month = ""
  let day = ""
  for (const part of format.formatToParts(seconds * 1000)) {
    if (part.type === "year") year = part.value
    else if (part.type === "month") month = part.value
    else if (part.type === "day") day = part.value
  }
  const key = `${year.padStart(4, "0")}-${month}-${day}`
  if (cache.size >= DAY_CACHE_LIMIT) cache.clear()
  cache.set(bucket, key)
  return key
}

// ---------------------------------------------------------------------------
// Rules

const compareIds = (a: MessageID, b: MessageID): number => {
  const left = BigInt(a)
  const right = BigInt(b)
  return left < right ? -1 : left > right ? 1 : 0
}

const isOwn = (row: MessageRow, viewerId: UserID): boolean => row.out || row.fromId === viewerId

/** Whether two adjacent messages share a sender run. Mac: `canGroup`. */
export const canGroup = (
  earlier: MessageRow,
  later: MessageRow,
  timeZone: string,
  breaksGroup?: TimelineItemsInput["breaksGroup"],
): boolean => {
  if (earlier.fromId !== later.fromId) return false
  if (later.date - earlier.date > GROUP_MAX_GAP_SECONDS) return false
  if (dayKeyOf(earlier.date, timeZone) !== dayKeyOf(later.date, timeZone)) return false
  if (breaksGroup?.(earlier, later)) return false
  return true
}

/**
 * The message the unread line sits above: the first message after the
 * boundary that is not the viewer's own. Undefined when the window does not
 * reach the boundary (no read message in it and not the start of history),
 * because its first message may then not be the first unread one. Mac:
 * `ChatUnreadOpening.firstUnreadMessageId`.
 */
export const resolveUnreadLine = (
  rows: readonly MessageRow[],
  boundary: MessageID,
  viewerId: UserID,
  reachesHistoryStart = false,
): MessageID | undefined => {
  let containsRead = false
  let first: MessageID | undefined
  for (const row of rows) {
    const id = row.messageId
    if (id === undefined || BigInt(id) <= 0n) continue
    if (compareIds(id, boundary) <= 0) {
      containsRead = true
      continue
    }
    if (isOwn(row, viewerId)) continue
    if (first === undefined || compareIds(id, first) < 0) first = id
  }
  if (!containsRead && !reachesHistoryStart) return undefined
  return first
}

// ---------------------------------------------------------------------------
// Items

/**
 * Compute the items for a window. Keys are stable across updates: a message
 * keeps `m:<row id>`, a day keeps `d:<day>`, the unread line is `unread`.
 *
 * Pass the previous result's items as `previous` to keep the identity of
 * every item whose content did not change, so `===` tells a row view whether
 * to re-render.
 */
export const timelineItems = (
  input: TimelineItemsInput,
  previous?: readonly TimelineItem[],
): TimelineItemsResult => {
  const { rows, viewerId, timeZone, unread, breaksGroup } = input
  const lineAbove = unread
    ? (unread.lineAbove ?? resolveUnreadLine(rows, unread.boundary, viewerId, unread.reachesHistoryStart))
    : undefined

  const reuse = new Map<string, TimelineItem>()
  if (previous) for (const item of previous) reuse.set(item.key, item)

  const items: TimelineItem[] = []
  let lineShown = false
  let previousDay: string | undefined

  for (let index = 0; index < rows.length; index++) {
    const row = rows[index]!
    const dayKey = dayKeyOf(row.date, timeZone)

    if (!lineShown && lineAbove !== undefined && row.messageId === lineAbove) {
      lineShown = true
      const old = reuse.get(UNREAD_LINE_KEY)
      items.push(old ?? { kind: "unread", key: UNREAD_LINE_KEY })
    }

    if (dayKey !== previousDay) {
      previousDay = dayKey
      const key = daySeparatorKey(dayKey)
      const old = reuse.get(key)
      items.push(
        old?.kind === "day" && old.date === row.date ? old : { kind: "day", key, dayKey, date: row.date },
      )
    }

    const before = index > 0 ? rows[index - 1] : undefined
    const after = index + 1 < rows.length ? rows[index + 1] : undefined
    const firstInGroup = !before || !canGroup(before, row, timeZone, breaksGroup)
    const lastInGroup = !after || !canGroup(row, after, timeZone, breaksGroup)
    const key = messageItemKey(row)
    const old = reuse.get(key)
    items.push(
      old?.kind === "message" &&
        old.row === row &&
        old.firstInGroup === firstInGroup &&
        old.lastInGroup === lastInGroup &&
        old.dayKey === dayKey
        ? old
        : { kind: "message", key, row, firstInGroup, lastInGroup, dayKey },
    )
  }

  return { items, unreadLineAbove: lineAbove }
}
