/**
 * Base direction of user text, by the Apple clients' rule
 * (`InlineKit/RichContent/BlockContentDirection.swift`, same contract as the
 * server's `blockDirection.ts`):
 *
 * A text reads right to left when it has more right-to-left words than
 * left-to-right ones; a tie goes to its first strong letter. A word is a run
 * of letters, with the marks and joiners Arabic-script words carry inside
 * them; it counts for the direction of its first letter. Digits and
 * punctuation are neutral. A text with no letters has no direction of its own.
 *
 * This differs from the browser's `dir="auto"` (first strong character, UAX #9
 * P2), which reads "Claude Code حداقل ۲.۱ لازم دارد" as left to right. Use
 * `dir="auto"` only where a text has no letters.
 */

export type Direction = "ltr" | "rtl"
/** `auto` when the text has no letters; the element then follows the browser's rule. */
export type DirAttribute = Direction | "auto"

export type DirectionTally = {
  readonly rightToLeftWords: number
  readonly leftToRightWords: number
  /** Direction of the first strong letter; undefined when there are no letters. */
  readonly firstStrong: Direction | undefined
}

export const emptyTally: DirectionTally = { rightToLeftWords: 0, leftToRightWords: 0, firstStrong: undefined }

/** Words one direction must lead by for a paragraph to keep its own direction within a message. */
export const decisiveWordLead = 3

const letter = /[\p{L}\p{Nl}]/u
const mark = /\p{M}/u

/** The Apple clients' right-to-left letter ranges. */
export const isRightToLeftCodePoint = (codePoint: number): boolean =>
  (codePoint >= 0x0590 && codePoint <= 0x08ff) ||
  (codePoint >= 0xfb1d && codePoint <= 0xfdff) ||
  (codePoint >= 0xfe70 && codePoint <= 0xfeff) ||
  (codePoint >= 0x10800 && codePoint <= 0x10fff) ||
  (codePoint >= 0x1e800 && codePoint <= 0x1efff)

/** Counts strong words in `text[start, end)`. Offsets are UTF-16 code units. */
export const tallyDirection = (text: string, start = 0, end = text.length): DirectionTally => {
  let rightToLeftWords = 0
  let leftToRightWords = 0
  let firstStrong: Direction | undefined
  let inWord = false
  let index = Math.max(0, start)
  const stop = Math.min(text.length, end)
  while (index < stop) {
    const codePoint = text.codePointAt(index) ?? 0
    index += codePoint > 0xffff ? 2 : 1
    let isLetter: boolean
    if (codePoint < 0x80) {
      isLetter = (codePoint >= 0x41 && codePoint <= 0x5a) || (codePoint >= 0x61 && codePoint <= 0x7a)
    } else {
      const character = String.fromCodePoint(codePoint)
      if (mark.test(character) || codePoint === 0x200c || codePoint === 0x200d) continue
      isLetter = letter.test(character)
    }
    if (!isLetter) {
      inWord = false
      continue
    }
    if (inWord) continue
    inWord = true
    const rtl = isRightToLeftCodePoint(codePoint)
    if (rtl) rightToLeftWords += 1
    else leftToRightWords += 1
    if (firstStrong === undefined) firstStrong = rtl ? "rtl" : "ltr"
  }
  return { rightToLeftWords, leftToRightWords, firstStrong }
}

export const addTallies = (a: DirectionTally, b: DirectionTally): DirectionTally => ({
  rightToLeftWords: a.rightToLeftWords + b.rightToLeftWords,
  leftToRightWords: a.leftToRightWords + b.leftToRightWords,
  firstStrong: a.firstStrong ?? b.firstStrong,
})

/** The direction a tally decides, or undefined when it has no letters. */
export const tallyToDirection = (tally: DirectionTally): Direction | undefined => {
  if (tally.rightToLeftWords + tally.leftToRightWords === 0) return undefined
  if (tally.rightToLeftWords !== tally.leftToRightWords) {
    return tally.rightToLeftWords > tally.leftToRightWords ? "rtl" : "ltr"
  }
  return tally.firstStrong
}

/** The direction of `text` by word majority, or undefined when it has no letters. */
export const detectDirection = (text: string): Direction | undefined => tallyToDirection(tallyDirection(text))

/** A `dir` attribute value for a block of user text. */
export const dirAttribute = (text: string): DirAttribute => detectDirection(text) ?? "auto"

/**
 * The direction of one paragraph inside a message: its own, unless it leads
 * by fewer than `decisiveWordLead` words, in which case it follows the whole
 * message, so a reply streaming in as "Claude Code حداقل" doesn't start left to
 * right and flip once enough words arrive.
 */
export const leafDirection = (tally: DirectionTally, message: Direction | undefined): Direction | undefined => {
  const own = tallyToDirection(tally)
  if (own === undefined || message === undefined) return own
  const lead = Math.abs(tally.rightToLeftWords - tally.leftToRightWords)
  return lead < decisiveWordLead ? message : own
}
