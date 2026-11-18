/**
 * Pure decisions of the timeline: window sizes and edges, trimming, follow
 * zone, landings, jump plans, read marking and the jump-to-latest count. The
 * controller gathers the inputs from the host and applies the result; these
 * functions are tested as tables.
 */

import type { MessageID, UserID } from "@inline/ids"
import type { Command, MessageRow } from "@inline/core-protocol"
import {
  EXACT_BOTTOM_PX,
  FAR_JUMP_PHASE1_MS,
  FAR_JUMP_PHASE2_MS,
  FAR_JUMP_VIEWPORTS,
  FOLLOW_ZONE_PX,
  INITIAL_ROWS_BASE,
  INITIAL_ROWS_FALLBACK,
  INITIAL_ROWS_PX_PER_ROW,
  LOAD_MORE_VIEWPORTS,
  MIN_CORRECTION_PX,
  NEAR_JUMP_MS,
  TRIM_ABOVE_ROWS,
  TRIM_TO_ROWS,
} from "./constants"
import type { Easing } from "./host"

/** What the app forwards to the core as `{ kind: "ensure", sub, range }`. */
export type WindowRequest = Extract<Command, { kind: "ensure" }>["range"]

export const compareMessageIds = (a: MessageID, b: MessageID): number => {
  const left = BigInt(a)
  const right = BigInt(b)
  return left < right ? -1 : left > right ? 1 : 0
}

const maxId = (a: MessageID | undefined, b: MessageID | undefined): MessageID | undefined =>
  a === undefined ? b : b === undefined ? a : compareMessageIds(a, b) >= 0 ? a : b

const minId = (a: MessageID | undefined, b: MessageID | undefined): MessageID | undefined =>
  a === undefined ? b : b === undefined ? a : compareMessageIds(a, b) <= 0 ? a : b

export const clamp = (value: number, lower: number, upper: number): number =>
  Math.min(Math.max(value, lower), Math.max(lower, upper))

// ---------------------------------------------------------------------------
// Window

/** Rows in the first window and in each local page: `viewport / 24 + 30`. */
export const initialWindowSize = (viewportHeight: number): number =>
  viewportHeight > 0
    ? Math.floor(Math.round(viewportHeight) / INITIAL_ROWS_PX_PER_ROW) + INITIAL_ROWS_BASE
    : INITIAL_ROWS_FALLBACK

export type Range = { start: number; end: number }

export type EdgeInput = {
  offset: number
  viewportHeight: number
  contentHeight: number
  /** The rendered range, as indices into all loaded items. */
  range: Range
  /** Number of loaded items. */
  length: number
  hasOlder: boolean
  hasNewer: boolean
  /** An older or newer request is already in flight. */
  loadingOlder: boolean
  loadingNewer: boolean
  /** Rows to add per local page. */
  page: number
}

export type EdgePlan = {
  /** A wider rendered range, when loaded rows were outside it. */
  range?: Range
  requests: ("older" | "newer")[]
}

/**
 * Called only after user movement. Within one viewport of the top: render
 * more loaded rows, or ask the core for older ones. Same at the bottom.
 */
export const planEdges = (input: EdgeInput): EdgePlan => {
  const { offset, viewportHeight, contentHeight, range, length, page } = input
  const reach = viewportHeight * LOAD_MORE_VIEWPORTS
  const nearTop = offset < reach
  const nearBottom = contentHeight - viewportHeight - offset < reach
  let { start, end } = range
  const requests: ("older" | "newer")[] = []
  if (nearTop) {
    if (start > 0) start = Math.max(0, start - page)
    else if (input.hasOlder && !input.loadingOlder) requests.push("older")
  }
  if (nearBottom) {
    if (end < length) end = Math.min(length, end + page)
    else if (input.hasNewer && !input.loadingNewer) requests.push("newer")
  }
  const changed = start !== range.start || end !== range.end
  return changed ? { range: { start, end }, requests } : { requests }
}

export type TrimInput = {
  range: Range
  /** Item indices of the first and last visible rows. */
  firstVisible: number
  lastVisible: number
  /** Following latest keeps the newest rows. */
  following: boolean
}

/** Past `TRIM_ABOVE_ROWS` rendered rows, keep `TRIM_TO_ROWS` around the viewport. Null when nothing to trim. */
export const planTrim = (input: TrimInput): Range | null => {
  const { range, firstVisible, lastVisible, following } = input
  if (range.end - range.start <= TRIM_ABOVE_ROWS) return null
  if (following) return { start: range.end - TRIM_TO_ROWS, end: range.end }
  const center = Math.floor((firstVisible + lastVisible) / 2)
  const start = clamp(center - Math.floor(TRIM_TO_ROWS / 2), range.start, range.end - TRIM_TO_ROWS)
  // Never cut a visible row, even in a viewport taller than the kept rows.
  const keptStart = Math.min(start, firstVisible)
  const keptEnd = Math.max(start + TRIM_TO_ROWS, lastVisible + 1)
  return { start: Math.max(range.start, keptStart), end: Math.min(range.end, keptEnd) }
}

// ---------------------------------------------------------------------------
// Following latest

export const distanceFromBottom = (offset: number, viewportHeight: number, contentHeight: number): number =>
  contentHeight <= viewportHeight ? 0 : contentHeight - viewportHeight - offset

/**
 * Mac `isWithinFollowZone`: resting at the bottom (within 1 px) always
 * counts; within 44 px counts unless the user's last move was away from the
 * bottom.
 */
export const withinFollowZone = (distance: number, scrolledAway: boolean): boolean =>
  distance <= EXACT_BOTTOM_PX || (!scrolledAway && distance <= FOLLOW_ZONE_PX)

export const atExactBottom = (distance: number): boolean => distance <= EXACT_BOTTOM_PX

// ---------------------------------------------------------------------------
// Landings

export type LandingInput = {
  /** Current scroll offset. */
  offset: number
  /** Top of the row to land on, in viewport coordinates. */
  rowTop: number
  viewportHeight: number
  contentHeight: number
  insetTop: number
  /** Distance of the row's top below the uncovered top. */
  hold: number
}

const maxOffset = (viewportHeight: number, contentHeight: number) => Math.max(0, contentHeight - viewportHeight)

/**
 * The offset that opens with a row `hold` px below the uncovered top, or null
 * when the rows from there down fit on screen (the chat then opens at the
 * bottom, holding nothing). Mac: `UnreadLineGeometry.landingOrigin`.
 */
export const landingOffset = (input: LandingInput): number | null => {
  const upper = maxOffset(input.viewportHeight, input.contentHeight)
  const target = input.offset + input.rowTop - input.insetTop - input.hold
  if (target >= upper - MIN_CORRECTION_PX) return null
  return Math.max(0, target)
}

/** The offset that keeps a held row `hold` px below the uncovered top, clamped. Mac: `heldOrigin`. */
export const heldOffset = (input: LandingInput): number =>
  clamp(
    input.offset + input.rowTop - input.insetTop - input.hold,
    0,
    maxOffset(input.viewportHeight, input.contentHeight),
  )

/**
 * The offset that centers a row in the uncovered part of the viewport,
 * clamped. Mac: `centeredScrollY`. A row taller than the uncovered part
 * cannot be centered usefully (its middle would fill the screen and its
 * start, the photo above a long caption for example, would be off screen):
 * its top goes to the top of the uncovered part instead.
 */
export const centeredOffset = (input: {
  offset: number
  rowTop: number
  rowBottom: number
  viewportHeight: number
  contentHeight: number
  insetTop: number
  insetBottom: number
}): number => {
  const visible = input.viewportHeight - input.insetTop - input.insetBottom
  const max = maxOffset(input.viewportHeight, input.contentHeight)
  if (input.rowBottom - input.rowTop > visible) return clamp(input.offset + input.rowTop - input.insetTop, 0, max)
  const middle = input.offset + (input.rowTop + input.rowBottom) / 2
  return clamp(middle - input.insetTop - visible / 2, 0, max)
}

// ---------------------------------------------------------------------------
// Jumps

export type JumpPhase = { to: number; duration: number; easing: Easing }

/**
 * Mac `scrollToMessage`: more than two viewports away, ease in to half a
 * viewport short of the target (0.3 s), then ease out onto it (0.4 s);
 * otherwise one 0.4 s ease-in-out. Empty when already there.
 */
export const planJump = (from: number, to: number, viewportHeight: number): JumpPhase[] => {
  const distance = Math.abs(to - from)
  if (distance < MIN_CORRECTION_PX) return []
  if (distance > viewportHeight * FAR_JUMP_VIEWPORTS) {
    const short = to > from ? to - viewportHeight / 2 : to + viewportHeight / 2
    return [
      { to: short, duration: FAR_JUMP_PHASE1_MS, easing: "easeIn" },
      { to, duration: FAR_JUMP_PHASE2_MS, easing: "easeOut" },
    ]
  }
  return [{ to, duration: NEAR_JUMP_MS, easing: "easeInOut" }]
}

/**
 * Landing after the rows around a target replaced the window: start half a
 * viewport short, on the side the reader is coming from, and ease onto it
 * (the second phase of a far jump).
 */
export const planLanding = (to: number, viewportHeight: number, travel: "up" | "down"): { from: number; phase: JumpPhase } => ({
  from: travel === "up" ? to + viewportHeight / 2 : to - viewportHeight / 2,
  phase: { to, duration: FAR_JUMP_PHASE2_MS, easing: "easeOut" },
})

// ---------------------------------------------------------------------------
// Read marking (feature map rule 4)

export type ReadInput = {
  /** The app is active (window focused). */
  appActive: boolean
  /** The window is visible. */
  windowVisible: boolean
  /** The list has landed and is shown: not hidden for an unread fetch, not placing, not mid-jump. */
  placed: boolean
  withinFollowZone: boolean
  /** The rendered rows end at the live end of the chat. */
  atLiveEnd: boolean
  /** Newest message in the window; what "read all" marks. */
  newestMessageId?: MessageID
  /** Highest incoming message intersecting the viewport. */
  highestVisibleIncoming?: MessageID
  /**
   * The window is certified contiguous from the read marker up to this
   * message. Reading past it would cross an uncertified hole.
   */
  contiguousThrough?: MessageID
  /** Highest message already read or asked to be read. */
  readFrontier?: MessageID
}

export type ReadDecision =
  | { kind: "none" }
  | { kind: "readAll"; maxId: MessageID }
  | { kind: "readUpTo"; maxId: MessageID }

/**
 * Mac `updateUnreadIfNeeded`: only while the app is active and the window
 * visible, and only once the list has landed. At the live end inside the
 * follow zone, read everything; otherwise read up to the highest visible
 * incoming message, never past contiguous history and never backwards.
 */
export const decideRead = (input: ReadInput): ReadDecision => {
  if (!input.appActive || !input.windowVisible || !input.placed) return { kind: "none" }
  const frontier = input.readFrontier
  const ahead = (id: MessageID) => frontier === undefined || compareMessageIds(id, frontier) > 0
  if (input.withinFollowZone && input.atLiveEnd) {
    const newest = input.newestMessageId
    return newest !== undefined && ahead(newest) ? { kind: "readAll", maxId: newest } : { kind: "none" }
  }
  const visible = input.highestVisibleIncoming
  if (visible === undefined || input.contiguousThrough === undefined) return { kind: "none" }
  const target = minId(visible, input.contiguousThrough)!
  return ahead(target) ? { kind: "readUpTo", maxId: target } : { kind: "none" }
}

/** Incoming messages count as unread; your own never do. */
export const isIncoming = (row: MessageRow, viewerId: UserID): boolean => !row.out && row.fromId !== viewerId

/**
 * The number on "jump to latest" (feature map rule 5): the server's unread
 * count minus the incoming messages this list already asked to read that the
 * server has not caught up with. Mac: `ChatUnreadBadgeCount.resolve`.
 */
export const jumpToLatestCount = (input: {
  unreadCount: number
  readMaxId?: MessageID
  readFrontier?: MessageID
  contiguousThrough?: MessageID
  rows: Iterable<MessageRow>
  viewerId: UserID
}): number => {
  const unread = Math.max(0, input.unreadCount)
  const readMax = input.readMaxId ?? ("0" as MessageID)
  const frontier = input.readFrontier
  if (unread === 0 || frontier === undefined || compareMessageIds(frontier, readMax) <= 0) return unread
  const pendingMax = minId(frontier, input.contiguousThrough)
  if (pendingMax === undefined) return unread
  const pending = new Set<string>()
  for (const row of input.rows) {
    const id = row.messageId
    if (id === undefined || !isIncoming(row, input.viewerId)) continue
    if (compareMessageIds(id, readMax) > 0 && compareMessageIds(id, pendingMax) <= 0) pending.add(id)
  }
  return Math.max(0, unread - pending.size)
}

export { maxId as maxMessageId }
