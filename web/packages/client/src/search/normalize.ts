/**
 * Text folding and tokenization for the local message index.
 *
 * TypeScript owns tokenization. Text is folded and split into tokens here,
 * and the FTS5 table only splits on the single spaces this module emits (its
 * tokenizer treats every other character as part of a token). The indexed
 * text and the query therefore go through the same function, and matched
 * ranges are computed here from the same tokens FTS5 matched.
 *
 * Folding follows the Quick Search matcher
 * (`web/packages/view/src/quick-search/match.ts`, `normalizeText`):
 * lowercase, NFKD with combining marks dropped, Persian and Arabic letter
 * variants unified, Arabic-Indic and Persian digits to ASCII, zero-width
 * joiners and non-joiners, bidi controls, tatweel and emoji skin tones
 * dropped, every other non-word character a separator. Letters, digits and
 * pictographs are word characters.
 *
 * Two additions for a full-text index:
 * - Characters of scripts written without spaces (Han, Hiragana, Katakana,
 *   Hangul syllables, Thai, Lao, Khmer, Myanmar, Bopomofo) and pictographs
 *   are tokens of their own (unigrams). A query in those scripts becomes a
 *   phrase of consecutive characters, so any substring is found.
 * - Hangul syllables are kept whole instead of being decomposed into jamo,
 *   so one syllable is one token.
 *
 * Nothing here throws, whatever the input.
 */

/** Bump when folding or tokenization changes: the index is rebuilt in the background. */
export const SEARCH_NORMALIZER_VERSION = 1

/** Source text past this many UTF-16 units is not indexed. */
export const MAX_INDEXED_TEXT_LENGTH = 32_768

export type SearchToken = {
  /** Folded token text, no spaces. */
  readonly text: string
  /** UTF-16 offsets of the token in the source text, `[start, end)`. */
  readonly start: number
  readonly end: number
  /** No separator between this token and the previous one in the source. */
  readonly joined: boolean
  /** A unigram of a script written without spaces, or a pictograph. */
  readonly isolated: boolean
  /** For each UTF-16 unit of `text`: its end offset in the source (prefix highlights). */
  readonly unitEnds?: readonly number[]
}

const wordChar = /[\p{L}\p{N}\p{Extended_Pictographic}]/u
const ignorableChar =
  /^[\p{M}​-‍⁠﻿‎‏؜‪-‮⁦-⁩ـ]$/u
const isSkinTone = (cp: number): boolean => cp >= 0x1f3fb && cp <= 0x1f3ff
const isIgnorable = (char: string): boolean =>
  isSkinTone(char.codePointAt(0) ?? 0) || ignorableChar.test(char)

/** Scripts written without spaces between words, and pictographs: one token per character. */
const isolatedChar =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Bopomofo}\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}\p{Script=Myanmar}ーｰ가-힣\p{Extended_Pictographic}]/u
const isHangulSyllable = (cp: number): boolean => cp >= 0xac00 && cp <= 0xd7a3

const letterVariants: Readonly<Record<string, string>> = {
  "ك": "ک", // Arabic kaf → Persian keheh
  "ي": "ی", // Arabic yeh → Farsi yeh
  "ى": "ی", // alef maksura → Farsi yeh
  "ە": "ه", // ae (the base of heh with yeh above, after NFKD) → heh
  "ة": "ه", // teh marbuta → heh
  "ٱ": "ا", // alef wasla → alef
}

const foldDigit = (cp: number): number => {
  if (cp >= 0x0660 && cp <= 0x0669) return cp - 0x0660 + 48
  if (cp >= 0x06f0 && cp <= 0x06f9) return cp - 0x06f0 + 48
  return cp
}

type Folded = { readonly out: string; readonly isolated: boolean } | null

const foldCache = new Map<number, Folded>()

/** What one non-ASCII code point becomes: word units and spaces, or null when ignorable. */
const foldCodePoint = (cp: number): Folded => {
  const cached = foldCache.get(cp)
  if (cached !== undefined) return cached
  let result: Folded
  const char = String.fromCodePoint(cp)
  if (isIgnorable(char)) {
    result = null
  } else if (isHangulSyllable(cp)) {
    result = { out: char, isolated: true }
  } else {
    let out = ""
    for (const part of char.toLowerCase().normalize("NFKD")) {
      if (isIgnorable(part)) continue
      const mapped =
        letterVariants[part] ?? String.fromCodePoint(foldDigit(part.codePointAt(0) ?? 0))
      out += wordChar.test(mapped) ? mapped : " "
    }
    const isolated = isolatedChar.test(char) && out.trim().length > 0
    result = out.length === 0 ? null : { out: isolated ? out.replaceAll(" ", "") : out, isolated }
  }
  if (foldCache.size < 20_000) foldCache.set(cp, result)
  return result
}

type MutableToken = {
  text: string
  start: number
  end: number
  joined: boolean
  isolated: boolean
  unitEnds?: number[]
}

/**
 * Split `text` into folded tokens with their source offsets. `withUnits`
 * also records where each folded unit ends in the source, for highlighting
 * a prefix of a token.
 */
export const tokenize = (
  text: unknown,
  options: { withUnits?: boolean; maxLength?: number } = {},
): SearchToken[] => {
  if (typeof text !== "string" || text.length === 0) return []
  const withUnits = options.withUnits === true
  const length = Math.min(text.length, options.maxLength ?? text.length)
  const tokens: MutableToken[] = []
  let current: MutableToken | null = null
  let separated = true

  const close = () => {
    if (current) tokens.push(current)
    current = null
  }

  const appendUnit = (unit: string, start: number, end: number) => {
    if (!current) {
      current = {
        text: "",
        start,
        end,
        joined: !separated && tokens.length > 0,
        isolated: false,
        ...(withUnits ? { unitEnds: [] } : {}),
      }
    }
    current.text += unit
    current.end = end
    current.unitEnds?.push(end)
    separated = false
  }

  const separate = () => {
    close()
    separated = true
  }

  let i = 0
  while (i < length) {
    const code = text.charCodeAt(i)
    if (code < 0x80) {
      if (code >= 65 && code <= 90) appendUnit(String.fromCharCode(code + 32), i, i + 1)
      else if ((code >= 97 && code <= 122) || (code >= 48 && code <= 57)) appendUnit(text[i] ?? "", i, i + 1)
      else separate()
      i++
      continue
    }
    const cp = text.codePointAt(i) ?? code
    const width = cp > 0xffff ? 2 : 1
    const folded = foldCodePoint(cp)
    if (folded === null) {
      // A mark or joiner belongs to the character before it.
      const owner: MutableToken | undefined = current ?? (separated ? undefined : tokens[tokens.length - 1])
      if (owner && owner.end === i) {
        owner.end = i + width
        const units = owner.unitEnds
        if (units && units.length > 0) units[units.length - 1] = i + width
      }
    } else if (folded.isolated) {
      const joined = !separated && (current !== null || tokens.length > 0)
      close()
      tokens.push({
        text: folded.out,
        start: i,
        end: i + width,
        joined,
        isolated: true,
        ...(withUnits ? { unitEnds: Array.from({ length: folded.out.length }, () => i + width) } : {}),
      })
      separated = false
    } else {
      for (let k = 0; k < folded.out.length; k++) {
        const unit = folded.out[k] ?? " "
        if (unit === " ") separate()
        else appendUnit(unit, i, i + width)
      }
    }
    i += width
  }
  close()
  return tokens
}

/** The text stored in the FTS5 index: folded tokens separated by one space. */
export const indexText = (text: unknown): string => {
  const tokens = tokenize(text, { maxLength: MAX_INDEXED_TEXT_LENGTH })
  let out = ""
  for (const token of tokens) out += out.length === 0 ? token.text : ` ${token.text}`
  return out
}

/**
 * cyrb53: a fast 53-bit string hash. The index stores it per message so a
 * message written again with the same text does not rewrite its entry.
 */
export const textHash = (value: string): number => {
  let h1 = 0xdeadbeef
  let h2 = 0x41c6ce57
  for (let i = 0; i < value.length; i++) {
    const ch = value.charCodeAt(i)
    h1 = Math.imul(h1 ^ ch, 2654435761)
    h2 = Math.imul(h2 ^ ch, 1597334677)
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507)
  h1 ^= Math.imul(h2 ^ (h2 >>> 13), 3266489909)
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507)
  h2 ^= Math.imul(h1 ^ (h1 >>> 13), 3266489909)
  return 4294967296 * (2097151 & h2) + (h1 >>> 0)
}
