/**
 * The composer's `:` suggestions: a `suggest` function of the shape the
 * composer model takes (`SuggestFn`, `web/src/features/composer/autocomplete.ts`),
 * the same shape as the mentions source (`web/src/features/mentions/suggest.ts`),
 * so the chat pane can combine both:
 *
 *   suggest: (trigger) => trigger.kind === "mention" ? mentions.suggest(trigger) : emoji.suggest(trigger)
 *
 * Mac rules (`ComposeEmojiAutocompleteProvider.swift`, `ComposeAutocompleteViewModel.swift`,
 * `EmojiAutocompleteDetector.swift`):
 *
 * - The trigger is the composer package's `detectEmoji`, a port of the Mac
 *   detector: `:` not after a letter, digit or `_`, then ASCII letters,
 *   digits, `_`, `+` or `-`. It fires from the first character
 *   (`detectsAfterOneCharacter`); the ranking keeps one-character queries to
 *   exact shortcodes and aliases (":x" → ❌, ":o" → 😮), so a one-letter
 *   query shows at most a few rows. `minQueryLength` can raise that.
 * - 8 rows (`ComposeAutocompleteViewModel.limit`), ranked with the user's
 *   frecency; each row is ":shortcode:" with the CLDR name and the emoji in
 *   the preferred tone, which is what accepting inserts (no trailing space).
 * - There is no conversion of a typed `:shortcode:` on the closing colon on
 *   the Mac: the detector stops at the second colon
 *   (`doesNotDetectAfterCompletedShortcode`), and so does `detectEmoji`.
 *
 * - An accepted row counts for recents and frecency through its `onAccept`
 *   (the composer calls it once per accepted row, never for a dismissed list).
 *
 * Synchronous once the data is loaded. The first `:` starts loading it and
 * shows nothing; the list fills in when it arrives, because `suggest` reads
 * the loader's signal. Small, and imports no data.
 */

import type { Trigger } from "@inline/composer"
import type { ComposerSuggestion } from "../composer/autocomplete"
import type { EmojiInfo } from "./engine"
import type { EmojiServices } from "./services"
import type { SkinTone } from "./tone"

/** A `:` suggestion row; `emoji` is what accepting inserts. */
export type EmojiSuggestion = ComposerSuggestion & { readonly emoji: string; readonly info: EmojiInfo }

export type EmojiSuggestOptions = {
  readonly services: Pick<EmojiServices, "loader" | "usage" | "support">
  /** Rows. Default 8. */
  readonly limit?: number
  /** Shortest query that searches. Default 1, as on the Mac. */
  readonly minQueryLength?: number
  /** Where a load is started from inside a computed. Default a microtask. */
  readonly defer?: (fn: () => void) => void
}

export type EmojiSuggest = {
  /** The composer model's `suggest` option: rows for an emoji trigger, nothing for others. */
  readonly suggest: (trigger: Trigger) => readonly EmojiSuggestion[]
  /** Rows for a query (the text after `:`). */
  rows(query: string): readonly EmojiSuggestion[]
  /**
   * Count an accepted row for frecency (`ComposeEmojiAutocompleteProvider.recordSelection`).
   * Each row's `onAccept` already does this when the composer accepts it.
   */
  recordAccepted(emoji: string): void
}

const none: readonly EmojiSuggestion[] = Object.freeze([])

export const createEmojiSuggest = (options: EmojiSuggestOptions): EmojiSuggest => {
  const { loader, usage, support } = options.services
  const limit = options.limit ?? 8
  const minQueryLength = Math.max(1, options.minQueryLength ?? 1)
  const defer = options.defer ?? ((fn: () => void) => queueMicrotask(fn))
  const cache = new WeakMap<EmojiInfo, Map<SkinTone, EmojiSuggestion>>()

  const row = (info: EmojiInfo, emoji: string, tone: SkinTone): EmojiSuggestion => {
    let byTone = cache.get(info)
    if (!byTone) cache.set(info, (byTone = new Map()))
    let suggestion = byTone.get(tone)
    if (!suggestion) {
      suggestion = {
        id: `emoji-${info.emoji}`,
        title: `:${info.shortcode}:`,
        subtitle: info.label,
        glyph: emoji,
        item: { kind: "emoji", text: emoji },
        // The composer calls this once the row was accepted (never for a dismissed list).
        onAccept: () => usage.record(emoji),
        emoji,
        info,
      }
      byTone.set(tone, suggestion)
    }
    return suggestion
  }

  const rows = (query: string): readonly EmojiSuggestion[] => {
    if (query.length < minQueryLength) return none
    const engine = loader.engine.get()
    if (!engine) {
      if (loader.status.peek() === "idle") defer(() => void loader.load().catch(() => undefined))
      return none
    }
    usage.revision.get()
    support.revision.get()
    const tone = usage.skinTone.get()
    const out: EmojiSuggestion[] = []
    for (const info of engine.search(query, { limit: limit * 2, usage: usage.scores() })) {
      if (!support.isSupported(info.emoji)) continue
      out.push(row(info, engine.withTone(info.emoji, tone), tone))
      if (out.length >= limit) break
    }
    return out
  }

  return {
    suggest: (trigger) => (trigger.kind === "emoji" ? rows(trigger.query) : none),
    rows,
    recordAccepted: (emoji) => usage.record(emoji),
  }
}
