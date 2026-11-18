/**
 * The emoji engine: the parsed table, the search index and the Mac's ranking.
 * This module and the generated table form the lazily loaded emoji chunk;
 * nothing else imports it statically (`loader.ts` imports it with `import()`).
 *
 * Search is a port of `EmojiAutocomplete.suggestions`
 * (`apple/InlineUI/Sources/EmojiAutocomplete/EmojiAutocomplete.swift`); line
 * numbers below refer to that file. Terms and queries are compared as UTF-8
 * bytes, as there (see `utf8Binary`).
 */

import { EMOJI_POPULAR, EMOJI_ROWS, EMOJI_SECTIONS } from "./data/emoji-data.generated"
import { normalize, utf8Binary } from "./normalize"
import { applySkinTone, usageKey, type SkinTone } from "./tone"

/** One base emoji (skin tone variants are folded into `tone`). */
export type EmojiInfo = {
  /** The base emoji, with VS16 where the data has it. */
  readonly emoji: string
  readonly shortcode: string
  /** The CLDR name, "grinning face". */
  readonly label: string
  /** Tone template (`tone.ts`): `""` when the emoji takes no skin tone. */
  readonly tone: string
  /** Position in the table (Unicode order); the final tie-break of search. */
  readonly index: number
}

export type EmojiSection = { readonly id: string; readonly title: string; readonly items: readonly EmojiInfo[] }

/** Personal usage scores by usage key (`EmojiUsageSnapshot`). */
export type UsageScores = { readonly score: (key: string) => number }

export const EMPTY_USAGE: UsageScores = { score: () => 0 }

/** Term kinds, strongest first (`EmojiAutocompleteTerm.Kind`). */
const Kind = { shortcode: 0, alias: 1, keyword: 2 } as const
type Kind = (typeof Kind)[keyof typeof Kind]

type Term = { readonly value: string; readonly compact: string; readonly kind: Kind }
type Word = { readonly value: string; readonly kind: Kind }

type Entry = {
  readonly info: EmojiInfo
  readonly usageKey: string
  readonly terms: readonly Term[]
  readonly words: readonly Word[]
  readonly popularityBoost: number
  readonly shortcodeLength: number
}

/** Tiers, lower is better (lines 177-213). */
const Scoring = {
  exactShortcode: 0,
  exactAlias: 3,
  exactStrongWord: 10,
  exactKeyword: 14,
  shortcodePrefix: 18,
  aliasPrefix: 20,
  strongWordPrefix: 23,
  multiWord: 24,
  keywordPrefix: 27,
  compactPrefix: 28,
  fuzzy: 38,
  substring: 40,
  maxUsageBoost: 7,
} as const

/** Prefers the tighter completion: "hea" ranks "heart" above "headphone" (line 194). */
const tightness = (extra: number) => Math.min(6, Math.max(0, extra) * 0.35)
const exactTier = (kind: Kind) => (kind === Kind.shortcode ? Scoring.exactShortcode : kind === Kind.alias ? Scoring.exactAlias : Scoring.exactKeyword)
const prefixTier = (kind: Kind) => (kind === Kind.shortcode ? Scoring.shortcodePrefix : kind === Kind.alias ? Scoring.aliasPrefix : Scoring.keywordPrefix)

/** The usage boost of a score (`EmojiUsageSnapshot.boost`, lines 171-174). */
export const usageBoost = (score: number): number => (score > 0 ? Math.min(Scoring.maxUsageBoost, 3 * Math.log2(1 + score)) : 0)

const stripUnderscores = (value: string) => (value.includes("_") ? value.replaceAll("_", "") : value)

/** Terms from the shortcode, aliases and keywords; a repeat keeps its first (stronger) kind (lines 86-103). */
const makeTerms = (shortcode: string, aliases: readonly string[], keywords: readonly string[]): Term[] => {
  const out: Term[] = []
  const seen = new Set<string>()
  const add = (value: string, kind: Kind) => {
    if (value === "" || seen.has(value)) return
    seen.add(value)
    out.push({ value, compact: stripUnderscores(value), kind })
  }
  add(normalize(shortcode), Kind.shortcode)
  // Aliases and keywords are stored normalized by the generator.
  for (const alias of aliases) add(alias, Kind.alias)
  for (const keyword of keywords) add(keyword, Kind.keyword)
  return out
}

/** Words of every term, each with the strongest kind it appears in, in first-seen order (lines 105-121). */
const makeWords = (terms: readonly Term[]): Word[] => {
  const kinds = new Map<string, Kind>()
  for (const term of terms) {
    for (const word of term.value.split("_")) {
      if (word === "") continue
      const existing = kinds.get(word)
      if (existing === undefined || term.kind < existing) kinds.set(word, term.kind)
    }
  }
  return Array.from(kinds, ([value, kind]) => ({ value, kind }))
}

const splitList = (value: string | undefined): string[] => (value ? value.split(",") : [])

type Query = { readonly bytes: string; readonly compact: string; readonly tokens: readonly string[]; readonly length: number; readonly isMultiWord: boolean }

const makeQuery = (raw: string): Query | undefined => {
  const normalized = normalize(raw)
  if (normalized === "") return undefined
  const bytes = utf8Binary(normalized)
  const compact = stripUnderscores(bytes)
  const tokens = bytes.split("_").filter((token) => token !== "")
  return { bytes, compact, tokens, length: compact.length, isMultiWord: tokens.length > 1 }
}

/** Exact, prefix, compact and word matches (lines 351-391). */
const strictTier = (entry: Entry, query: Query): number | undefined => {
  const q = query.bytes
  const length = query.length
  let best = Number.POSITIVE_INFINITY

  for (const term of entry.terms) {
    if (term.value === q) {
      // Single characters are too noisy to match CLDR keywords ("o", "x").
      if (length === 1 && term.kind === Kind.keyword) continue
      best = Math.min(best, exactTier(term.kind))
      continue
    }
    if (length < 2) continue
    if (term.value.startsWith(q)) {
      // Two letters are ambiguous; only complete shortcodes ("he" → heart, not "hehe" → joy).
      if (length === 2 && term.kind !== Kind.shortcode) continue
      best = Math.min(best, prefixTier(term.kind) + tightness(term.value.length - q.length))
    } else if (length >= 3 && term.compact.startsWith(query.compact)) {
      const tier = term.compact.length === query.compact.length ? exactTier(term.kind) + 1 : Scoring.compactPrefix
      best = Math.min(best, tier + tightness(term.compact.length - query.compact.length))
    }
  }

  if (length >= 2 && !query.isMultiWord) {
    for (const word of entry.words) {
      const strong = word.kind !== Kind.keyword
      if (word.value === q) {
        best = Math.min(best, strong ? Scoring.exactStrongWord : Scoring.exactKeyword)
      } else if (word.value.startsWith(q) && (length >= 3 || word.kind === Kind.shortcode)) {
        best = Math.min(best, (strong ? Scoring.strongWordPrefix : Scoring.keywordPrefix) + tightness(word.value.length - q.length))
      }
    }
  }

  if (query.isMultiWord) {
    const tier = multiWordTier(entry, query.tokens)
    if (tier !== undefined) best = Math.min(best, tier)
  }

  return Number.isFinite(best) ? best : undefined
}

/** Every token must start a distinct word, in any order: "heart red", "cat smile" (lines 393-414). */
const multiWordTier = (entry: Entry, tokens: readonly string[]): number | undefined => {
  const used = new Set<number>()
  let penalty = 0
  for (const token of tokens) {
    let bestIndex = -1
    let bestPenalty = 0
    entry.words.forEach((word, index) => {
      if (used.has(index) || !word.value.startsWith(token)) return
      let wordPenalty = word.value.length === token.length ? 0 : 1.5
      if (word.kind === Kind.keyword) wordPenalty += 1
      if (bestIndex < 0 || wordPenalty < bestPenalty) {
        bestIndex = index
        bestPenalty = wordPenalty
      }
    })
    if (bestIndex < 0) return undefined
    used.add(bestIndex)
    penalty += bestPenalty
  }
  return Scoring.multiWord + penalty
}

/** The shortcode contains the query (lines 416-419). */
const containsSubstring = (entry: Entry, query: Query): boolean => {
  const shortcode = entry.terms[0]
  if (!shortcode || shortcode.kind !== Kind.shortcode || query.compact === "") return false
  return shortcode.compact.includes(query.compact)
}

/** One typo against shortcodes, aliases and strong words (lines 421-443). */
const fuzzyTier = (entry: Entry, query: Query): number | undefined => {
  const q = query.compact
  // In four-letter words a changed or extra letter is usually a different word; only a missing or swapped letter counts.
  const allowsSubstitution = q.length >= 5
  let best = Number.POSITIVE_INFINITY
  const consider = (value: string) => {
    if (value.charCodeAt(0) !== q.charCodeAt(0) || !prefixWithinOneEdit(q, value, allowsSubstitution)) return
    best = Math.min(best, Scoring.fuzzy + tightness(value.length - q.length))
  }
  for (const term of entry.terms) if (term.kind !== Kind.keyword) consider(term.compact)
  for (const word of entry.words) if (word.kind !== Kind.keyword) consider(word.value)
  return Number.isFinite(best) ? best : undefined
}

/** `query` is one insertion, deletion, substitution or adjacent swap from some prefix of `value` (lines 445-453). */
const prefixWithinOneEdit = (query: string, value: string, allowsSubstitution: boolean): boolean => {
  const lengths = allowsSubstitution ? [query.length, query.length + 1, query.length - 1] : [query.length, query.length + 1]
  for (const length of lengths) {
    if (length > 0 && length <= value.length && withinOneEdit(query, value.slice(0, length), allowsSubstitution)) return true
  }
  return false
}

/** Lines 455-485. */
const withinOneEdit = (a: string, b: string, allowsSubstitution: boolean): boolean => {
  if (a.length === b.length) {
    const mismatches: number[] = []
    for (let i = 0; i < a.length; i++) {
      if (a.charCodeAt(i) !== b.charCodeAt(i)) {
        mismatches.push(i)
        if (mismatches.length > 2) return false
      }
    }
    if (mismatches.length === 0) return true
    if (mismatches.length === 1) return allowsSubstitution
    const [i = 0, j = 0] = mismatches
    return j === i + 1 && a[i] === b[j] && a[j] === b[i]
  }
  const [longer, shorter] = a.length > b.length ? [a, b] : [b, a]
  if (longer.length - shorter.length !== 1) return false
  let i = 0
  let j = 0
  let skipped = false
  while (i < longer.length && j < shorter.length) {
    if (longer.charCodeAt(i) === shorter.charCodeAt(j)) {
      i++
      j++
    } else {
      if (skipped) return false
      skipped = true
      i++
    }
  }
  return true
}

export type SearchOptions = {
  /** Most results. Default 8, as on the Mac. */
  readonly limit?: number
  /** Personal usage (`EmojiUsage.scores()`). */
  readonly usage?: UsageScores
}

export type EmojiEngine = {
  /** Every base emoji in Unicode order. */
  readonly all: readonly EmojiInfo[]
  /** The browse sections in the standard order (`EmojiPickerData.defaultSections`). */
  readonly sections: readonly EmojiSection[]
  /**
   * Base emoji matching a query, best first (`EmojiAutocomplete.suggestions`).
   * Apply the preferred skin tone when displaying.
   */
  search(query: string, options?: SearchOptions): readonly EmojiInfo[]
  /** The dataset entry for an emoji, ignoring skin tone and VS16 (`EmojiAutocomplete.suggestion(forEmoji:)`). */
  lookup(emoji: string): EmojiInfo | undefined
  /** The emoji in a skin tone, when it takes one; unchanged otherwise. */
  withTone(emoji: string, tone: SkinTone): string
}

const parse = (): { entries: Entry[]; sections: EmojiSection[] } => {
  const popular = new Map<string, number>()
  const ranked = EMOJI_POPULAR.split(" ")
  ranked.forEach((emoji, rank) => {
    const key = usageKey(emoji)
    // `boostByUsageKey` (EmojiAutocompleteAliases.swift lines 343-352): the first rank of a key wins.
    if (!popular.has(key)) popular.set(key, 4 + 8 * (1 - rank / ranked.length))
  })

  const entries: Entry[] = EMOJI_ROWS.split("\n").map((line, index) => {
    const [emoji = "", shortcode = "", label = "", aliases, keywords, tone = ""] = line.split("\t")
    const terms = makeTerms(shortcode, splitList(aliases), splitList(keywords))
    const key = usageKey(emoji)
    return {
      info: { emoji, shortcode, label, tone, index },
      usageKey: key,
      terms,
      words: makeWords(terms),
      popularityBoost: popular.get(key) ?? 0,
      shortcodeLength: utf8Binary(shortcode).length,
    }
  })

  const starts = EMOJI_SECTIONS.split("\n").map((line) => {
    const [id = "", title = "", start = "0"] = line.split("\t")
    return { id, title, start: Number(start) }
  })
  const sections = starts.map((section, i) => {
    const end = starts[i + 1]?.start ?? entries.length
    return { id: section.id, title: section.title, items: entries.slice(section.start, end).map((entry) => entry.info) }
  })
  return { entries, sections }
}

/** Build the engine. Parses the table and indexes it (a few milliseconds); call once and keep it. */
export const createEmojiEngine = (): EmojiEngine => {
  const { entries, sections } = parse()

  // Entries keyed by the first byte of any term or word (`EmojiAutocompleteIndex`, lines 126-153).
  const buckets: number[][] = Array.from({ length: 256 }, () => [])
  entries.forEach((entry, index) => {
    const seen = new Set<number>()
    const add = (value: string) => {
      const first = value.charCodeAt(0)
      if (Number.isNaN(first) || seen.has(first)) return
      seen.add(first)
      buckets[first]?.push(index)
    }
    for (const term of entry.terms) add(term.value)
    for (const word of entry.words) add(word.value)
  })

  const byUsageKey = new Map<string, Entry>()
  for (const entry of entries) if (!byUsageKey.has(entry.usageKey)) byUsageKey.set(entry.usageKey, entry)

  const search = (raw: string, options: SearchOptions = {}): readonly EmojiInfo[] => {
    const limit = options.limit ?? 8
    const query = makeQuery(raw)
    if (limit <= 0 || !query) return []
    const usage = options.usage ?? EMPTY_USAGE

    const scored: { score: number; entry: number }[] = []
    const matched = new Set<number>()
    const append = (index: number, tier: number) => {
      const entry = entries[index] as Entry
      scored.push({ score: tier - entry.popularityBoost - usageBoost(usage.score(entry.usageKey)), entry: index })
      matched.add(index)
    }

    const firstByte = (query.compact || query.bytes).charCodeAt(0)
    const candidates = buckets[firstByte] ?? []
    for (const index of candidates) {
      const tier = strictTier(entries[index] as Entry, query)
      if (tier !== undefined) append(index, tier)
    }

    // Weak tiers only fill in when the strict ones come up thin; they never depend on `limit` (lines 287-306).
    const strictCount = matched.size
    if (query.length >= 4 && strictCount < 3) {
      for (const index of candidates) {
        if (matched.has(index)) continue
        const tier = fuzzyTier(entries[index] as Entry, query)
        if (tier !== undefined) append(index, tier)
      }
    }
    if (query.length >= 4 && strictCount < 5) {
      for (let index = 0; index < entries.length; index++) {
        if (!matched.has(index) && containsSubstring(entries[index] as Entry, query)) append(index, Scoring.substring)
      }
    }

    // Score, then the shorter shortcode, then table order (lines 308-315).
    scored.sort((a, b) => {
      if (a.score !== b.score) return a.score - b.score
      const lengthA = (entries[a.entry] as Entry).shortcodeLength
      const lengthB = (entries[b.entry] as Entry).shortcodeLength
      if (lengthA !== lengthB) return lengthA - lengthB
      return a.entry - b.entry
    })
    return scored.slice(0, limit).map((item) => (entries[item.entry] as Entry).info)
  }

  const lookup = (emoji: string) => byUsageKey.get(usageKey(emoji))?.info

  return {
    all: entries.map((entry) => entry.info),
    sections,
    search,
    lookup,
    withTone: (emoji, tone) => applySkinTone(emoji, tone, lookup(emoji)?.tone),
  }
}
