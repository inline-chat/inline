/**
 * Reaction chips: order and labels. Mac: `Views/Reactions/ReactionChipOrdering.swift`
 * sorts by count, highest first, then by emoji (Swift string order, which for
 * emoji is code point order).
 */

import type { ReactionSummary } from "@inline/core-protocol"
import { reactionTooltip, type Reactor } from "../emoji/display"

/** Compare two strings by Unicode code point, not UTF-16 code unit. */
export const compareCodePoints = (a: string, b: string): number => {
  const left = a[Symbol.iterator]()
  const right = b[Symbol.iterator]()
  for (;;) {
    const l = left.next()
    const r = right.next()
    if (l.done) return r.done ? 0 : -1
    if (r.done) return 1
    const lc = l.value.codePointAt(0) ?? 0
    const rc = r.value.codePointAt(0) ?? 0
    if (lc !== rc) return lc < rc ? -1 : 1
  }
}

const compareReactions = (a: ReactionSummary, b: ReactionSummary): number =>
  a.count !== b.count ? b.count - a.count : compareCodePoints(a.emoji, b.emoji)

const ordered = new WeakMap<readonly ReactionSummary[], readonly ReactionSummary[]>()
const empty: readonly ReactionSummary[] = Object.freeze([])

/**
 * Chips in display order: by count, highest first, then by emoji. Reactions
 * with no count are dropped. Rows are immutable, so the result is cached per
 * array and keeps its identity while the row's reactions do.
 */
export const orderReactions = (reactions: readonly ReactionSummary[] | undefined): readonly ReactionSummary[] => {
  if (!reactions || reactions.length === 0) return empty
  const cached = ordered.get(reactions)
  if (cached) return cached
  const result = Object.freeze(reactions.filter((reaction) => reaction.count > 0).sort(compareReactions))
  ordered.set(reactions, result)
  return result
}

/** The accessible name of a chip: "👍 3, including you". */
export const reactionLabel = (reaction: ReactionSummary): string =>
  `${reaction.emoji} ${reaction.count}${reaction.mine ? ", including you" : ""}`

/**
 * A chip's tooltip: who reacted ("Ada, You", the emoji feature's
 * `reactionTooltip`). `ReactionSummary` has no reactors yet, so without them
 * it says "You" only when the viewer is the one reactor, and nothing
 * otherwise (no invented names).
 */
export const reactionChipTooltip = (
  reaction: ReactionSummary,
  reactors: readonly Reactor[] | undefined,
  viewerId: string | undefined,
): string | undefined => {
  if (reactors) return reactionTooltip(reactors, viewerId) || undefined
  return reaction.mine && reaction.count === 1 ? "You" : undefined
}
