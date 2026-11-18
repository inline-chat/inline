/**
 * Invariant 5: certified history coverage, as pure range arithmetic.
 *
 * A chat's coverage is the list of inclusive message-ID ranges the server has
 * certified as complete: every message in a certified range is stored, and an
 * ID in the range without a stored row does not exist. Anything not certified
 * is a hole, whether or not rows are cached there. This mirrors InlineKit's
 * `MessageHistoryCoverageStore`, which stores the complement (holes).
 *
 * Message IDs are positive int64; the arithmetic runs on `bigint`.
 */
import { int64Max, messageId, type MessageID } from "@inline/ids"
import type { HistoryCoverage } from "./models"

/** The open top of a range certified through the newest message. */
export const HISTORY_TOP = int64Max

export type HistoryRange = readonly [bigint, bigint]

export const coverageRanges = (
  coverage: Pick<HistoryCoverage, "ranges"> | undefined,
): HistoryRange[] =>
  (coverage?.ranges ?? []).map(([from, to]) => [BigInt(from), BigInt(to)])

export const coverageModelRanges = (
  ranges: readonly HistoryRange[],
): Array<[MessageID, MessageID]> =>
  ranges.map(([from, to]) => [messageId(from), messageId(to)])

/** Sorted, merged (overlapping or adjacent), clamped to [1, HISTORY_TOP]. */
export const normalizeRanges = (
  ranges: readonly HistoryRange[],
): HistoryRange[] => {
  const sorted = ranges
    .map(([from, to]): HistoryRange => [
      from < 1n ? 1n : from,
      to > HISTORY_TOP ? HISTORY_TOP : to,
    ])
    .filter(([from, to]) => from <= to)
    .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0))
  const merged: Array<[bigint, bigint]> = []
  for (const [from, to] of sorted) {
    const last = merged.at(-1)
    if (last && from <= last[1] + 1n) {
      if (to > last[1]) last[1] = to
    } else {
      merged.push([from, to])
    }
  }
  return merged
}

export const certifyRanges = (
  existing: readonly HistoryRange[],
  added: readonly HistoryRange[],
): HistoryRange[] => normalizeRanges([...existing, ...added])

/** True when every ID in [from, to] is certified. An empty interval is. */
export const isCertified = (
  ranges: readonly HistoryRange[],
  from: bigint,
  to: bigint,
): boolean => {
  if (from > to) return true
  return ranges.some(([lower, upper]) => lower <= from && to <= upper)
}

/** The certified range holding `id`, if any. */
export const certifiedRangeAt = (
  ranges: readonly HistoryRange[],
  id: bigint,
): HistoryRange | undefined =>
  ranges.find(([lower, upper]) => lower <= id && id <= upper)

/**
 * How far a read frontier may move from `current` toward `requested` without
 * crossing uncertified history (InlineKit's `certifiedReadMaxID`). Returns
 * undefined when it cannot move at all.
 */
export const certifiedReadMaxId = (
  ranges: readonly HistoryRange[],
  current: bigint,
  requested: bigint,
): bigint | undefined => {
  const frontier = current < 0n ? 0n : current
  if (requested <= frontier) return undefined
  let reach = frontier
  while (reach < requested) {
    const range = certifiedRangeAt(ranges, reach + 1n)
    if (!range) break
    reach = range[1]
  }
  const capped = reach < requested ? reach : requested
  return capped > frontier ? capped : undefined
}

export type WindowEdges = {
  hasOlder: boolean
  hasNewer: boolean
  atLatest: boolean
}

/**
 * The edges of a window holding server messages `oldest`..`newest` (none
 * when empty), for a chat whose newest known message is `lastMsgId`.
 *
 * - `hasOlder` is false when the window starts at message 1, or when
 *   everything below it is certified and an older load found no rows there
 *   (`olderExhausted`). Certified history below the window still has stored
 *   rows to show, so certification alone does not end it.
 * - `atLatest` needs the window to reach the newest known message and,
 *   once the chat has any coverage, the range above it to be certified.
 *   A chat with no coverage yet (an older replica, or offline before any
 *   page) trusts its local rows for this, as before.
 */
export const windowEdges = (input: {
  ranges: readonly HistoryRange[]
  oldest?: bigint
  newest?: bigint
  lastMsgId?: bigint
  olderExhausted?: boolean
}): WindowEdges => {
  const { ranges, oldest, newest, lastMsgId } = input
  const known = ranges.length > 0
  const hasOlder =
    oldest == null
      ? lastMsgId != null || !isCertified(ranges, 1n, HISTORY_TOP)
      : oldest > 1n &&
        !(input.olderExhausted === true && isCertified(ranges, 1n, oldest - 1n))
  const reachesLast =
    lastMsgId == null || (newest != null && newest >= lastMsgId)
  const topCertified = isCertified(
    ranges,
    (newest ?? 0n) + 1n,
    HISTORY_TOP,
  )
  const atLatest = reachesLast && (!known || topCertified)
  return { hasOlder, hasNewer: !atLatest, atLatest }
}

export type HistoryPageRequest = {
  mode: "latest" | "older" | "newer" | "around"
  limit?: number
  beforeId?: bigint
  afterId?: bigint
  anchorId?: bigint
  beforeLimit?: number
  afterLimit?: number
  includeAnchor?: boolean
}

const validLimit = (
  value: number | undefined,
  fallback: number,
  allowZero = false,
) => {
  const limit = value ?? fallback
  return Number.isInteger(limit) &&
    limit >= (allowZero ? 0 : 1) &&
    limit <= 100
    ? limit
    : undefined
}

/**
 * The ranges one `getChatHistory` page proves complete, from the request and
 * the IDs it returned (InlineKit's `provenCoverages`). A short page proves
 * history down to message 1 (or up to the top); an empty page proves its
 * whole requested side. Returns undefined for a page that does not match its
 * request, which then certifies nothing.
 */
export const provenRanges = (
  request: HistoryPageRequest,
  returned: readonly bigint[],
): HistoryRange[] | undefined => {
  if (returned.some((id) => id < 1n || id > HISTORY_TOP)) return undefined
  if (new Set(returned).size !== returned.length) return undefined
  const requested = validLimit(request.limit, 60)
  if (requested == null) return undefined
  const ids = returned.slice().sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
  const first = ids[0]
  const last = ids.at(-1)
  switch (request.mode) {
    case "latest": {
      if (ids.length > requested) return undefined
      return [[ids.length < requested ? 1n : first ?? 1n, HISTORY_TOP]]
    }
    case "older": {
      const before = request.beforeId
      if (before == null || ids.length > requested) return undefined
      if (ids.some((id) => id >= before)) return undefined
      if (before <= 1n) return []
      return [[ids.length < requested ? 1n : first ?? 1n, before - 1n]]
    }
    case "newer": {
      const after = request.afterId
      if (after == null || ids.length > requested) return undefined
      if (ids.some((id) => id <= after)) return undefined
      if (after >= HISTORY_TOP) return []
      return [
        [after + 1n, ids.length < requested ? HISTORY_TOP : last ?? HISTORY_TOP],
      ]
    }
    case "around": {
      const anchor = request.anchorId
      if (anchor == null) return undefined
      const includeAnchor = request.includeAnchor ?? true
      const anchorCount = includeAnchor && ids.includes(anchor) ? 1 : 0
      const beforeLimit = validLimit(
        request.beforeLimit,
        Math.floor(requested / 2),
        true,
      )
      const afterLimit = validLimit(
        request.afterLimit,
        Math.max(0, requested - Math.floor(requested / 2) - anchorCount),
        true,
      )
      if (
        beforeLimit == null ||
        afterLimit == null ||
        beforeLimit + afterLimit + anchorCount > 100
      ) {
        return undefined
      }
      const older = ids.filter((id) => id < anchor)
      const newer = ids.filter((id) => id > anchor)
      if (
        older.length > beforeLimit ||
        newer.length > afterLimit ||
        (!includeAnchor && ids.includes(anchor))
      ) {
        return undefined
      }
      const ranges: HistoryRange[] = []
      if (beforeLimit > 0 && anchor > 1n) {
        ranges.push([
          older.length < beforeLimit ? 1n : older[0] ?? 1n,
          anchor - 1n,
        ])
      }
      if (includeAnchor) ranges.push([anchor, anchor])
      if (afterLimit > 0 && anchor < HISTORY_TOP) {
        ranges.push([
          anchor + 1n,
          newer.length < afterLimit ? HISTORY_TOP : newer.at(-1) ?? HISTORY_TOP,
        ])
      }
      // Merge adjacent proofs, keeping a real gap at an excluded anchor.
      return normalizeRanges(ranges)
    }
  }
}
