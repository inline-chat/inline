/**
 * The quick reaction row's contents, a port of `ReactionPickerEmojis`
 * (`apple/InlineUI/Sources/ReactionPickerEmojis/ReactionPickerEmojis.swift`)
 * and of how `ReactionOverlayView.reloadSuggestedReactions` combines it
 * (`apple/InlineMac/Views/ReactionPicker/ReactionOverlayView.swift` lines
 * 100-122). Data-free: it uses the generated quick set only.
 */

import { LEGACY_ACKNOWLEDGEMENTS, QUICK_REACTION_TONES, QUICK_REACTIONS } from "./data/quick-reactions.generated"
import { applySkinTone, type SkinTone } from "./tone"
import { compareCodePoints, normalizedEmoji } from "./usage"

export { QUICK_REACTIONS }

const legacy = new Set(LEGACY_ACKNOWLEDGEMENTS)
const defaultIndex = new Map(QUICK_REACTIONS.map((emoji, index) => [emoji, index]))

/**
 * Reactions by how often the user picked them, then the default set
 * (`ReactionPickerEmojis.suggestions(from:limit:)`, lines 74-102): by count,
 * then default order, then emoji; the legacy acknowledgement marks never
 * appear. `limit` defaults to the size of the default set (15).
 */
export const suggestedReactions = (counts: ReadonlyMap<string, number>, limit: number = QUICK_REACTIONS.length): string[] => {
  if (limit <= 0) return []
  const normalized = new Map<string, number>()
  for (const [emoji, count] of counts) {
    if (!(count > 0)) continue
    const value = normalizedEmoji(emoji)
    if (!value || legacy.has(value)) continue
    normalized.set(value, (normalized.get(value) ?? 0) + count)
  }
  const ranked = [...normalized]
    .sort(([a, countA], [b, countB]) => {
      if (countA !== countB) return countB - countA
      const indexA = defaultIndex.get(a)
      const indexB = defaultIndex.get(b)
      if (indexA !== undefined && indexB !== undefined) return indexA - indexB
      if (indexA !== undefined) return -1
      if (indexB !== undefined) return 1
      return compareCodePoints(a, b)
    })
    .map(([emoji]) => emoji)
  const out: string[] = []
  for (const emoji of [...ranked, ...QUICK_REACTIONS]) {
    if (out.length >= limit) break
    if (!out.includes(emoji)) out.push(emoji)
  }
  return out
}

let segmenter: Intl.Segmenter | undefined
const graphemes = (text: string) => {
  segmenter ??= new Intl.Segmenter(undefined, { granularity: "grapheme" })
  return segmenter.segment(text)
}

const emojiScalar = /\p{Emoji}/u
const emojiModifier = /\p{Emoji_Modifier}/u
const emojiPresentation = /\p{Emoji_Presentation}/u

/** Whether a grapheme of a message counts as an emoji to offer (`isMessageEmoji`, lines 49-63). */
export const isMessageEmoji = (grapheme: string): boolean => {
  const first = grapheme.codePointAt(0)
  if (first === undefined) return false
  const head = String.fromCodePoint(first)
  if (!emojiScalar.test(head) || emojiModifier.test(head) || grapheme.includes("︎")) return false
  // Digits, # and * are emoji only with the enclosing keycap.
  if (first < 0x80) return grapheme.includes("⃣")
  return emojiPresentation.test(head) || first > 0x238c || grapheme.includes("️")
}

/**
 * The message's own emoji first, as written (tone kept), then the usual
 * suggestions, without repeats, up to `limit` (`prioritizingMessageEmojis`, lines 29-47).
 */
export const prioritizingMessageEmojis = (
  messageText: string | null | undefined,
  among: readonly string[],
  limit: number = QUICK_REACTIONS.length,
  /** Message emoji to keep (the ones this platform draws). Default all. */
  keep?: (emoji: string) => boolean,
): string[] => {
  if (limit <= 0) return []
  const out: string[] = []
  const add = (emoji: string) => {
    if (out.length < limit && !out.includes(emoji)) out.push(emoji)
  }
  if (messageText) {
    for (const { segment } of graphemes(messageText)) {
      if (!isMessageEmoji(segment) || (keep && !keep(segment))) continue
      add(segment)
      if (out.length === limit) return out
    }
  }
  for (const emoji of among) {
    add(emoji)
    if (out.length === limit) break
  }
  return out
}

/** One button of the quick row. */
export type QuickReaction = {
  /** As shown and as sent. */
  readonly emoji: string
  /** The stored pick it comes from (before the tone), for "Remove from suggestions". */
  readonly source: string
  /** From the message's text; sent exactly as shown. */
  readonly fromMessage: boolean
  /** The user picked it before, so it can be removed from suggestions. */
  readonly removable: boolean
  /** The viewer already reacted with it (choosing it removes the reaction). */
  readonly mine: boolean
}

export type QuickRowInput = {
  readonly counts: ReadonlyMap<string, number>
  readonly messageText?: string | null
  readonly tone: SkinTone
  /** Tone templates; the engine's once loaded, the quick set's before. */
  readonly toneTemplate?: (emoji: string) => string | undefined
  /** Emoji the viewer already reacted with. */
  readonly mine?: ReadonlySet<string>
  readonly limit?: number
  /**
   * Whether this platform draws an emoji (as shown, toned). One it cannot
   * is skipped and the next suggestion takes its place, as the grid hides
   * it. Default: everything draws.
   */
  readonly supported?: (emoji: string) => boolean
}

const quickTemplate = (emoji: string) => QUICK_REACTION_TONES[emoji]

/**
 * The row as the Mac builds it on open: suggestions from pick counts, each
 * in the preferred tone (a tone collision keeps the first), then the
 * message's emoji in front. Emoji the platform cannot draw are left out
 * and do not take a place: the next suggestion (from the default set at
 * the end) fills it.
 */
export const quickRow = (input: QuickRowInput): QuickReaction[] => {
  const limit = input.limit ?? QUICK_REACTIONS.length
  const template = input.toneTemplate ?? quickTemplate
  const supported = input.supported
  const sourceOf = new Map<string, string>()
  const displayed: string[] = []
  // The Mac takes `limit` suggestions, then drops tone collisions; places
  // are counted the same way here, except that undrawable ones are free.
  let places = 0
  for (const source of suggestedReactions(input.counts, Number.POSITIVE_INFINITY)) {
    if (places >= limit) break
    const shown = applySkinTone(source, input.tone, template(source) ?? quickTemplate(source))
    if (supported && !supported(shown)) continue
    places += 1
    if (sourceOf.has(shown)) continue
    sourceOf.set(shown, source)
    displayed.push(shown)
  }
  const fromMessage = new Set(prioritizingMessageEmojis(input.messageText, [], limit, supported))
  return prioritizingMessageEmojis(input.messageText, displayed, limit, supported).map((emoji) => {
    const source = sourceOf.get(emoji) ?? emoji
    const isFromMessage = fromMessage.has(emoji)
    return {
      emoji,
      source,
      fromMessage: isFromMessage,
      removable: !isFromMessage && (input.counts.get(source) ?? 0) > 0,
      mine: input.mine?.has(emoji) ?? false,
    }
  })
}
