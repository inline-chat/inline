/**
 * The Quick Search matcher: names and titles against a typed query.
 *
 * A port of the Mac matcher (`InlineKit/Sources/InlineSearch/InlineSearchMatcher.swift`)
 * with three additions the web needs: matched ranges for highlighting (UTF-16
 * offsets into the original text), an acronym tier ("pm" finds "Product
 * Meeting"), and explicit folding of Persian and Arabic letter variants.
 *
 * Text is normalized once per field (`prepareField`) and once per query
 * (`prepareQuery`); matching a prepared query against prepared fields does no
 * allocation beyond the result. Nothing here throws, whatever the input.
 */

/**
 * Match quality, best last. The Mac tiers plus `acronym`, which sits between
 * a word-prefix match and a mid-word substring.
 */
export const MatchTier = {
  /** The query's letters appear in order somewhere in the field. */
  fuzzy: 1,
  /** The query without spaces appears in the field without spaces. */
  compact: 2,
  /** The query appears inside a word. */
  substring: 3,
  /** The query's letters are the initials of words, in order ("pm", "Product Meeting"). */
  acronym: 4,
  /** Every query word starts a word of the field. */
  tokenPrefix: 5,
  /** The field starts with the query. */
  fieldPrefix: 6,
  /** The field is the query. */
  exact: 7,
} as const

export type MatchTier = (typeof MatchTier)[keyof typeof MatchTier]

/** A half-open range `[start, end)` in UTF-16 code units of the original text. */
export type MatchRange = readonly [start: number, end: number]

export type PreparedQuery = {
  /** The query as typed, trimmed. */
  readonly raw: string
  /** Folded, words separated by one space. */
  readonly normalized: string
  /** `normalized` without spaces. */
  readonly compact: string
  readonly tokens: readonly string[]
}

export type PreparedField = {
  /** The original text. Ranges point into it. */
  readonly text: string
  readonly priority: number
  readonly normalized: string
  readonly compact: string
  /** For each UTF-16 unit of `normalized`: where it came from in `text`. */
  readonly starts: Int32Array
  readonly ends: Int32Array
  /** Word boundaries in `normalized`, as start and end indexes. */
  readonly tokenStarts: Int32Array
  readonly tokenEnds: Int32Array
  /** For each UTF-16 unit of `compact`: its index in `normalized`. */
  readonly compactToNormalized: Int32Array
}

export type Match = {
  readonly tier: MatchTier
  /** Higher is better. Orders like `compareMatches`. */
  readonly score: number
  /** Index of the matched field in the list given to `matchFields`. */
  readonly fieldIndex: number
  readonly fieldPriority: number
  /** Where the match starts: a word index for word matches, else a position in the normalized field. */
  readonly position: number
  /** Length of the normalized field; shorter wins a tie. */
  readonly fieldLength: number
  /** Ranges to highlight, in UTF-16 offsets of the matched field's original text, sorted and merged. */
  readonly ranges: readonly MatchRange[]
}

// ---------------------------------------------------------------------------
// Normalization

/** Letters, digits and pictographs make words; anything else separates them. */
const wordChar = /[\p{L}\p{N}\p{Extended_Pictographic}]/u
/**
 * Dropped without separating words: combining marks (accents, Arabic
 * harakat, variation selectors), zero-width joiners and non-joiners, bidi
 * controls, the Arabic tatweel, emoji skin tones.
 */
const ignorableChar = /^[\p{M}\u200B-\u200D\u2060\uFEFF\u200E\u200F\u061C\u202A-\u202E\u2066-\u2069\u0640]$/u
const isSkinTone = (cp: number): boolean => cp >= 0x1f3fb && cp <= 0x1f3ff
const ignorable = { test: (char: string): boolean => isSkinTone(char.codePointAt(0) ?? 0) || ignorableChar.test(char) }

/** Persian and Arabic letters typed differently on different keyboards, folded to one form. */
const letterVariants: Readonly<Record<string, string>> = {
  "ك": "ک", // Arabic kaf → Persian keheh
  "ي": "ی", // Arabic yeh → Farsi yeh
  "ى": "ی", // alef maksura → Farsi yeh
  "ە": "ه", // ae (the base of heh with yeh above, after NFKD) → heh
  "ة": "ه", // teh marbuta → heh
  "ٱ": "ا", // alef wasla → alef
}

const foldDigit = (cp: number): number => {
  if (cp >= 0x0660 && cp <= 0x0669) return cp - 0x0660 + 48 // Arabic-Indic
  if (cp >= 0x06f0 && cp <= 0x06f9) return cp - 0x06f0 + 48 // Persian
  return cp
}

/**
 * What one non-ASCII code point becomes: folded word characters, " " for a
 * separator, or `null` for an ignorable character. Cached per code point.
 */
const foldCache = new Map<number, string | null>()

const foldCodePoint = (cp: number): string | null => {
  const cached = foldCache.get(cp)
  if (cached !== undefined) return cached
  let result: string | null
  const char = String.fromCodePoint(cp)
  if (ignorable.test(char)) {
    result = null
  } else {
    let out = ""
    for (const part of char.toLowerCase().normalize("NFKD")) {
      if (ignorable.test(part)) continue
      const mapped = letterVariants[part] ?? String.fromCodePoint(foldDigit(part.codePointAt(0) ?? 0))
      out += wordChar.test(mapped) ? mapped : " "
    }
    // A character that decomposes to marks only (rare) is ignorable too.
    result = out.length === 0 ? null : out
  }
  if (foldCache.size < 20_000) foldCache.set(cp, result)
  return result
}

type Normalized = {
  normalized: string
  starts: Int32Array
  ends: Int32Array
}

const normalizeWithMap = (text: string): Normalized => {
  const length = text.length
  // Folding can expand a character (ligatures, NFKD), so size generously and trim.
  let capacity = length + 8
  let starts = new Int32Array(capacity)
  let ends = new Int32Array(capacity)
  const parts: string[] = []
  let size = 0
  let pendingSeparator = false

  const push = (unit: string, start: number, end: number) => {
    if (size + 1 > capacity) {
      capacity *= 2
      const nextStarts = new Int32Array(capacity)
      const nextEnds = new Int32Array(capacity)
      nextStarts.set(starts)
      nextEnds.set(ends)
      starts = nextStarts
      ends = nextEnds
    }
    parts.push(unit)
    starts[size] = start
    ends[size] = end
    size++
  }

  const emit = (chars: string, start: number, end: number) => {
    for (let k = 0; k < chars.length; k++) {
      const unit = chars[k] ?? ""
      if (unit === " ") {
        pendingSeparator = true
        continue
      }
      if (pendingSeparator && size > 0) push(" ", start, start)
      pendingSeparator = false
      push(unit, start, end)
    }
  }

  let i = 0
  while (i < length) {
    const code = text.charCodeAt(i)
    if (code < 0x80) {
      if (code >= 65 && code <= 90) emit(String.fromCharCode(code + 32), i, i + 1)
      else if ((code >= 97 && code <= 122) || (code >= 48 && code <= 57)) emit(text[i] ?? "", i, i + 1)
      else pendingSeparator = true
      i++
      continue
    }
    const cp = text.codePointAt(i) ?? code
    const width = cp > 0xffff ? 2 : 1
    const folded = foldCodePoint(cp)
    if (folded === null) {
      // A mark belongs to the character before it: highlight them together.
      if (size > 0 && !pendingSeparator && ends[size - 1] === i) {
        let k = size - 1
        const owner = starts[k]
        while (k >= 0 && starts[k] === owner) ends[k--] = i + width
      }
    } else {
      emit(folded, i, i + width)
    }
    i += width
  }

  return { normalized: parts.join(""), starts: starts.subarray(0, size), ends: ends.subarray(0, size) }
}

/**
 * Fold text for matching: lowercase, NFKD without combining marks, Persian
 * and Arabic variants unified, zero-width characters dropped, and every run
 * of non-word characters turned into one space.
 */
export const normalizeText = (text: string): string => {
  if (typeof text !== "string" || text.length === 0) return ""
  return normalizeWithMap(text).normalized
}

const tokenBounds = (normalized: string): { starts: Int32Array; ends: Int32Array } => {
  const starts: number[] = []
  const ends: number[] = []
  let start = 0
  for (let k = 0; k <= normalized.length; k++) {
    if (k === normalized.length || normalized.charCodeAt(k) === 32) {
      if (k > start) {
        starts.push(start)
        ends.push(k)
      }
      start = k + 1
    }
  }
  return { starts: Int32Array.from(starts), ends: Int32Array.from(ends) }
}

/** Prepare a query. Undefined when it has no word characters: treat it as empty. */
export const prepareQuery = (query: string): PreparedQuery | undefined => {
  if (typeof query !== "string") return undefined
  const normalized = normalizeText(query)
  const compact = normalized.replaceAll(" ", "")
  if (compact.length === 0) return undefined
  return { raw: query.trim(), normalized, compact, tokens: normalized.split(" ") }
}

/** Prepare one field of a candidate. Undefined when the text has no word characters. */
export const prepareField = (text: string | undefined | null, priority: number): PreparedField | undefined => {
  if (typeof text !== "string" || text.length === 0) return undefined
  const { normalized, starts, ends } = normalizeWithMap(text)
  if (normalized.length === 0) return undefined
  const tokens = tokenBounds(normalized)
  const compactToNormalized = new Int32Array(normalized.length)
  let size = 0
  for (let k = 0; k < normalized.length; k++) {
    if (normalized.charCodeAt(k) === 32) continue
    compactToNormalized[size++] = k
  }
  const compact = normalized.replaceAll(" ", "")
  return {
    text,
    priority: Number.isFinite(priority) ? priority : 0,
    normalized,
    compact,
    starts,
    ends,
    tokenStarts: tokens.starts,
    tokenEnds: tokens.ends,
    compactToNormalized: compactToNormalized.subarray(0, size),
  }
}

/** Prepare several fields, dropping empty ones. */
export const prepareFields = (fields: readonly { readonly text: string | undefined | null; readonly priority: number }[]): PreparedField[] => {
  const out: PreparedField[] = []
  for (const field of fields) {
    const prepared = prepareField(field.text, field.priority)
    if (prepared) out.push(prepared)
  }
  return out
}

// ---------------------------------------------------------------------------
// Matching

/** The Mac order: tier, then field priority, then earlier position, then shorter field. Negative when `a` is better. */
export const compareMatches = (a: Match, b: Match): number => {
  if (a.tier !== b.tier) return b.tier - a.tier
  if (a.fieldPriority !== b.fieldPriority) return b.fieldPriority - a.fieldPriority
  if (a.position !== b.position) return a.position - b.position
  return a.fieldLength - b.fieldLength
}

const scoreOf = (tier: number, priority: number, position: number, fieldLength: number): number =>
  tier * 100_000_000 + Math.max(0, Math.min(priority, 99_999)) * 1_000 + (99 - Math.min(position, 99)) * 10 + (9 - Math.min(Math.floor(fieldLength / 8), 9))

/** Normalized `[start, end)` ranges to original ranges, sorted and merged. */
const toOriginal = (field: PreparedField, ranges: number[]): MatchRange[] => {
  const out: [number, number][] = []
  for (let k = 0; k + 1 < ranges.length; k += 2) {
    const a = ranges[k] ?? 0
    const b = ranges[k + 1] ?? 0
    if (b <= a) continue
    const start = field.starts[a] ?? 0
    const end = field.ends[b - 1] ?? start
    out.push([start, end])
  }
  out.sort((x, y) => x[0] - y[0])
  const merged: [number, number][] = []
  for (const range of out) {
    const last = merged[merged.length - 1]
    if (last && range[0] <= last[1]) last[1] = Math.max(last[1], range[1])
    else merged.push([range[0], range[1]])
  }
  return merged
}

const result = (
  tier: MatchTier,
  field: PreparedField,
  fieldIndex: number,
  position: number,
  normalizedRanges: number[],
): Match => ({
  tier,
  score: scoreOf(tier, field.priority, position, field.normalized.length),
  fieldIndex,
  fieldPriority: field.priority,
  position,
  fieldLength: field.normalized.length,
  ranges: toOriginal(field, normalizedRanges),
})

const tokenPrefixMatch = (query: PreparedQuery, field: PreparedField): { position: number; ranges: number[] } | undefined => {
  const count = field.tokenStarts.length
  const used: boolean[] = []
  const ranges: number[] = []
  let earliest = Number.MAX_SAFE_INTEGER
  for (const token of query.tokens) {
    let found = -1
    // Prefer a word no earlier query word took, so "an an" needs two words.
    for (let pass = 0; pass < 2 && found < 0; pass++) {
      for (let t = 0; t < count; t++) {
        if (pass === 0 && used[t]) continue
        const start = field.tokenStarts[t] ?? 0
        const end = field.tokenEnds[t] ?? 0
        if (end - start >= token.length && field.normalized.startsWith(token, start)) {
          found = t
          break
        }
      }
    }
    if (found < 0) return undefined
    used[found] = true
    const start = field.tokenStarts[found] ?? 0
    ranges.push(start, start + token.length)
    earliest = Math.min(earliest, found)
  }
  return { position: earliest, ranges }
}

const acronymMatch = (query: PreparedQuery, field: PreparedField): { position: number; ranges: number[] } | undefined => {
  if (query.tokens.length !== 1 || field.tokenStarts.length < 2) return undefined
  const letters = query.compact
  if (letters.length < 2 || letters.length > field.tokenStarts.length * 2) return undefined
  const ranges: number[] = []
  let position = -1
  let t = 0
  let q = 0
  while (q < letters.length) {
    const cp = letters.codePointAt(q) ?? 0
    const width = cp > 0xffff ? 2 : 1
    let found = false
    while (t < field.tokenStarts.length) {
      const start = field.tokenStarts[t] ?? 0
      t++
      if (field.normalized.codePointAt(start) === cp) {
        if (position < 0) position = t - 1
        ranges.push(start, start + width)
        found = true
        break
      }
    }
    if (!found) return undefined
    q += width
  }
  return { position: Math.max(0, position), ranges }
}

const fuzzyMatch = (query: string, field: PreparedField): number[] | undefined => {
  const compact = field.compact
  const ranges: number[] = []
  let f = 0
  for (let q = 0; q < query.length; q++) {
    const unit = query.charCodeAt(q)
    while (f < compact.length && compact.charCodeAt(f) !== unit) f++
    if (f >= compact.length) return undefined
    const n = field.compactToNormalized[f] ?? 0
    const last = ranges.length - 1
    if (last >= 1 && ranges[last] === n) ranges[last] = n + 1
    else ranges.push(n, n + 1)
    f++
  }
  return ranges
}

const compactRange = (field: PreparedField, start: number, length: number): number[] => {
  const ranges: number[] = []
  for (let k = start; k < start + length; k++) {
    const n = field.compactToNormalized[k] ?? 0
    const last = ranges.length - 1
    if (last >= 1 && ranges[last] === n) ranges[last] = n + 1
    else ranges.push(n, n + 1)
  }
  return ranges
}

/** Match a prepared query against one prepared field. */
export const matchField = (query: PreparedQuery, field: PreparedField, fieldIndex = 0): Match | undefined => {
  const text = field.normalized
  const q = query.normalized
  if (text === q) return result(MatchTier.exact, field, fieldIndex, 0, [0, text.length])
  if (text.startsWith(q)) return result(MatchTier.fieldPrefix, field, fieldIndex, 0, [0, q.length])

  const words = tokenPrefixMatch(query, field)
  if (words) return result(MatchTier.tokenPrefix, field, fieldIndex, words.position, words.ranges)

  const acronym = acronymMatch(query, field)
  if (acronym) return result(MatchTier.acronym, field, fieldIndex, acronym.position, acronym.ranges)

  const at = text.indexOf(q)
  if (at >= 0) return result(MatchTier.substring, field, fieldIndex, at, [at, at + q.length])

  const compactQuery = query.compact
  if (compactQuery.length >= 2) {
    const compactAt = field.compact.indexOf(compactQuery)
    if (compactAt >= 0) {
      return result(MatchTier.compact, field, fieldIndex, compactAt, compactRange(field, compactAt, compactQuery.length))
    }
  }

  // As on the Mac: three letters at least, and not across a long field.
  if (compactQuery.length < 3 || field.compact.length > compactQuery.length + 24) return undefined
  const fuzzy = fuzzyMatch(compactQuery, field)
  return fuzzy ? result(MatchTier.fuzzy, field, fieldIndex, 0, fuzzy) : undefined
}

/** The best match of a query over a candidate's fields, or undefined. */
export const matchFields = (query: PreparedQuery, fields: readonly PreparedField[]): Match | undefined => {
  let best: Match | undefined
  for (let index = 0; index < fields.length; index++) {
    const field = fields[index]
    if (!field) continue
    const candidate = matchField(query, field, index)
    if (candidate && (!best || compareMatches(candidate, best) < 0)) best = candidate
  }
  return best
}

/** Convenience for one-off use: match a raw query against raw text. */
export const matchText = (query: string, text: string, priority = 0): Match | undefined => {
  const prepared = prepareQuery(query)
  const field = prepareField(text, priority)
  return prepared && field ? matchField(prepared, field) : undefined
}
