/**
 * Settings search, ported from the Apple apps' `SettingsSearch`
 * (`apple/InlineUI/Sources/InlineUI/SettingsSearch.swift`): every query word
 * must prefix-match a word of the title, the keywords or the context (the
 * row's section and page title). Results rank title prefix over title word
 * over keyword over context; ties keep the index order. Matching ignores
 * case, diacritics and width.
 */

import type { SettingsItemSpec, SettingsPageId, SettingsPageSpec } from "./catalog"

export type SettingsSearchEntry = {
  readonly id: string
  readonly page: SettingsPageId
  readonly title: string
  readonly pageTitle: string
  readonly section: string
  readonly keywords: readonly string[]
  /** Section, then page title. */
  readonly context: readonly string[]
}

const SCORE = { titlePrefix: 8, titleWord: 4, keyword: 2, context: 1 } as const

/** Case, diacritic and width folded. */
export const foldText = (text: string): string =>
  text
    .normalize("NFKD")
    .replace(/\p{M}+/gu, "")
    .toLocaleLowerCase()

/** Words of letters and digits, folded. */
export const searchWords = (text: string): string[] => foldText(text).split(/[^\p{L}\p{N}]+/u).filter(Boolean)

/**
 * Index entries for the listed pages, in list order then row order. Rows on
 * pages that are not listed never match (the Mac rule: hidden pages never match).
 */
export const buildSearchIndex = (
  pages: readonly SettingsPageSpec[],
  items: readonly SettingsItemSpec[],
): readonly SettingsSearchEntry[] =>
  pages.flatMap((page) =>
    items
      .filter((spec) => spec.page === page.id)
      .map((spec) => ({
        id: spec.id,
        page: page.id,
        title: spec.title,
        pageTitle: page.title,
        section: spec.section,
        keywords: spec.keywords,
        context: [spec.section, page.title],
      })),
  )

type Prepared = {
  readonly entry: SettingsSearchEntry
  readonly title: string
  readonly titleWords: readonly string[]
  readonly keywordWords: readonly string[]
  readonly contextWords: readonly string[]
}

const prepared = new WeakMap<SettingsSearchEntry, Prepared>()

const prepare = (entry: SettingsSearchEntry): Prepared => {
  let value = prepared.get(entry)
  if (!value) {
    value = {
      entry,
      title: foldText(entry.title),
      titleWords: searchWords(entry.title),
      keywordWords: entry.keywords.flatMap(searchWords),
      contextWords: entry.context.flatMap(searchWords),
    }
    prepared.set(entry, value)
  }
  return value
}

const score = (entry: Prepared, tokens: readonly string[]): number | undefined => {
  let total = 0
  for (const token of tokens) {
    if (entry.title.startsWith(token)) total += SCORE.titlePrefix
    else if (entry.titleWords.some((word) => word.startsWith(token))) total += SCORE.titleWord
    else if (entry.keywordWords.some((word) => word.startsWith(token))) total += SCORE.keyword
    else if (entry.contextWords.some((word) => word.startsWith(token))) total += SCORE.context
    else return undefined
  }
  return total
}

/** Matching entries, best first. An empty or punctuation-only query matches nothing. */
export const searchSettings = (
  query: string,
  index: readonly SettingsSearchEntry[],
): readonly SettingsSearchEntry[] => {
  const tokens = searchWords(query)
  if (tokens.length === 0) return []
  const scored: { entry: SettingsSearchEntry; score: number; order: number }[] = []
  index.forEach((entry, order) => {
    const value = score(prepare(entry), tokens)
    if (value !== undefined) scored.push({ entry, score: value, order })
  })
  scored.sort((a, b) => (a.score !== b.score ? b.score - a.score : a.order - b.order))
  return scored.map((result) => result.entry)
}

/** The pages that have at least one result, in list order. */
export const pagesWithResults = (
  results: readonly SettingsSearchEntry[],
  pages: readonly SettingsPageSpec[],
): readonly SettingsPageId[] => pages.filter((page) => results.some((result) => result.page === page.id)).map((page) => page.id)
