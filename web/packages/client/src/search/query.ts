import { tokenize, type SearchToken } from "./normalize"

/**
 * The query language: what a user types, nothing more.
 *
 * - Words are separated by anything that is not a letter, digit or
 *   pictograph, after the same folding as the index (`normalize.ts`).
 * - Every word must match, in any order. Each matches as a prefix of a word
 *   in the message, as on the Mac (GRDB's `FTS5Pattern(matchingAllPrefixesIn:)`),
 *   so "proj meet" finds "project meeting".
 * - A run of characters with no separator (`東京`, `hello🎉`) is a phrase:
 *   its tokens must be consecutive.
 * - Text between double quotes is a phrase matched exactly (no prefix). An
 *   unclosed quote runs to the end and its last word is a prefix, since the
 *   user is still typing it.
 * - Everything else (`*`, `-`, `:`, `^`, `NEAR`, `AND`, parentheses) is plain
 *   text or a separator. No input can produce an FTS5 syntax error: every
 *   token reaches FTS5 inside a quoted string and never contains a quote.
 */

/** Queries longer than this many UTF-16 units are cut. */
export const MAX_QUERY_LENGTH = 512
/** At most this many phrases are matched; later ones are ignored. */
export const MAX_QUERY_GROUPS = 12
/** At most this many tokens per phrase. */
export const MAX_GROUP_TOKENS = 24
/**
 * A word shorter than this matches only itself, not as a prefix. A
 * one-letter prefix would read a large share of the index for little value
 * ("deploy t" is better served by "deploy" until the next letter).
 */
export const MIN_PREFIX_LENGTH = 2

export type QueryGroup = {
  /** Folded tokens that must be consecutive. */
  readonly tokens: readonly string[]
  /** The last token matches as a prefix. */
  readonly prefix: boolean
}

export type ParsedQuery = {
  readonly groups: readonly QueryGroup[]
  /** The FTS5 MATCH expression for the message text column. */
  readonly expression: string
}

const letterOrDigit = /[\p{L}\p{N}]/gu

/** The Mac rule (`LocalMessageSearch.isSearchable`): at least two letters or digits. */
export const isSearchableQuery = (query: unknown): boolean => {
  if (typeof query !== "string") return false
  const matches = query.slice(0, MAX_QUERY_LENGTH).match(letterOrDigit)
  return (matches?.length ?? 0) >= 2
}

const groupsOf = (
  tokens: readonly SearchToken[],
  mode: "words" | "phrase" | "open-phrase",
): QueryGroup[] => {
  if (tokens.length === 0) return []
  if (mode !== "words") {
    const last = tokens[tokens.length - 1]!
    return [
      {
        tokens: tokens.slice(0, MAX_GROUP_TOKENS).map((token) => token.text),
        prefix:
          mode === "open-phrase" &&
          tokens.length <= MAX_GROUP_TOKENS &&
          !last.isolated &&
          last.text.length >= MIN_PREFIX_LENGTH,
      },
    ]
  }
  const groups: QueryGroup[] = []
  let run: SearchToken[] = []
  const flush = () => {
    const last = run[run.length - 1]
    if (!last) return
    groups.push({
      tokens: run.slice(0, MAX_GROUP_TOKENS).map((token) => token.text),
      prefix:
        run.length <= MAX_GROUP_TOKENS &&
        !last.isolated &&
        last.text.length >= MIN_PREFIX_LENGTH,
    })
    run = []
  }
  for (const token of tokens) {
    if (!token.joined) flush()
    run.push(token)
  }
  flush()
  return groups
}

const quote = (token: string) => `"${token.replaceAll('"', '""')}"`

const phraseExpression = (group: QueryGroup) =>
  `${quote(group.tokens.join(" "))}${group.prefix ? " *" : ""}`

/**
 * Parse what the user typed. Undefined when there is nothing to search: the
 * query has fewer than two letters or digits, or no tokens.
 */
export const parseQuery = (query: unknown): ParsedQuery | undefined => {
  if (!isSearchableQuery(query)) return undefined
  const text = (query as string).slice(0, MAX_QUERY_LENGTH)
  const segments = text.split('"')
  const groups: QueryGroup[] = []
  const seen = new Set<string>()
  for (let index = 0; index < segments.length; index++) {
    const segment = segments[index] ?? ""
    const quoted = index % 2 === 1
    const open = quoted && index === segments.length - 1
    const mode = !quoted ? "words" : open ? "open-phrase" : "phrase"
    for (const group of groupsOf(tokenize(segment), mode)) {
      const key = `${group.prefix ? "*" : ""}${group.tokens.join(" ")}`
      if (seen.has(key)) continue
      seen.add(key)
      groups.push(group)
    }
  }
  if (groups.length === 0) return undefined
  const kept = groups.slice(0, MAX_QUERY_GROUPS)
  return {
    groups: kept,
    expression: kept.map(phraseExpression).join(" AND "),
  }
}

/** The full MATCH expression: the message text, optionally within one chat. */
export const matchExpression = (parsed: ParsedQuery, chatToken?: string): string =>
  chatToken
    ? `body : (${parsed.expression}) AND chat : ${quote(chatToken)}`
    : `body : (${parsed.expression})`
