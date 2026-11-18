/**
 * Emoji-only messages, by the Mac rules (`InlineKit/Extensions/StringExtensions.swift`
 * `Character.isEmoji` and `String.emojiInfo`, `MessageTextTypography.fontSize`):
 *
 * - A grapheme of one scalar is an emoji when that scalar has emoji presentation.
 * - A grapheme of several scalars is an emoji when any scalar has emoji
 *   presentation, is an emoji modifier or modifier base, or is VS16 or the
 *   combining keycap (so 1️⃣, ❤️ and 👍🏽 count).
 * - The text is emoji-only when every grapheme is an emoji, whitespace included
 *   (so "😀 😀" is not).
 * - One emoji renders at 64 pt, two or three at 42 pt, more at 18 pt.
 */

/** How large an emoji-only text renders; `none` for any other text. */
export type EmojiSize = "none" | "single" | "few" | "many"

const singleScalarEmoji = /^\p{Emoji_Presentation}$/u
const multiScalarEmoji = /[\p{Emoji_Presentation}\p{Emoji_Modifier}\p{Emoji_Modifier_Base}️⃣]/u

let segmenter: Intl.Segmenter | undefined

const graphemes = (text: string): Iterable<{ segment: string }> => {
  segmenter ??= new Intl.Segmenter(undefined, { granularity: "grapheme" })
  return segmenter.segment(text)
}

/** Whether one grapheme cluster counts as an emoji. */
export const isEmojiGrapheme = (grapheme: string): boolean => {
  const first = grapheme.codePointAt(0)
  if (first === undefined) return false
  const firstLength = first > 0xffff ? 2 : 1
  if (grapheme.length === firstLength) return singleScalarEmoji.test(grapheme)
  return multiScalarEmoji.test(grapheme)
}

/**
 * The emoji size class of a text. Stops at the first grapheme that is not an
 * emoji, so ordinary text costs one segment.
 */
export const emojiSize = (text: string): EmojiSize => {
  if (text.length === 0) return "none"
  let count = 0
  for (const { segment } of graphemes(text)) {
    if (!isEmojiGrapheme(segment)) return "none"
    count += 1
  }
  if (count === 0) return "none"
  if (count === 1) return "single"
  if (count <= 3) return "few"
  return "many"
}
