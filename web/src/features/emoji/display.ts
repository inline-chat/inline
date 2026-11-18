/**
 * Helpers for drawing reactions on a message, for the message feature to
 * use (it owns the chips; see README "Reaction display").
 */

import type { EmojiEngine } from "./engine"

export type Reactor = { readonly userId: string; readonly name: string }

/**
 * A chip's tooltip: who reacted, "You" for the viewer, in the order given,
 * joined with commas (`ReactionChipButton.updateContent`,
 * `apple/InlineMac/Views/Reactions/ReactionChipButton.swift` lines 235-241).
 * People whose names are not known yet are left out, as on the Mac.
 */
export const reactionTooltip = (reactors: readonly Reactor[], viewerId: string | undefined): string =>
  reactors
    .map((reactor) => (viewerId !== undefined && reactor.userId === viewerId ? "You" : reactor.name.trim()))
    .filter((name) => name !== "")
    .join(", ")

/**
 * The spoken name of an emoji: its CLDR name when the data has loaded
 * ("thumbs up"), else the emoji itself (screen readers have their own names).
 */
export const emojiName = (emoji: string, engine: EmojiEngine | undefined): string => engine?.lookup(emoji)?.label ?? emoji

/** A chip's accessible name: "thumbs up, 3, including you". */
export const reactionChipLabel = (input: { emoji: string; count: number; mine: boolean }, engine: EmojiEngine | undefined): string =>
  `${emojiName(input.emoji, engine)}, ${input.count}${input.mine ? ", including you" : ""}`
