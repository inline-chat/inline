/**
 * Reads the Mac app's emoji sources. Only data is read from Swift (string
 * literals, the generated table, dictionary and array literals); the rules
 * that use the data are ported by hand in `web/src/features/emoji/` with the
 * Swift lines cited.
 */

import { readFileSync } from "node:fs"
import { join } from "node:path"

/** The Swift files the web data comes from, relative to the repository root. */
export const SWIFT_SOURCES = {
  data: "apple/InlineUI/Sources/EmojiAutocomplete/EmojiAutocompleteData.generated.swift",
  aliases: "apple/InlineUI/Sources/EmojiAutocomplete/EmojiAutocompleteAliases.swift",
  pickerData: "apple/InlineUI/Sources/TextProcessing/EmojiPickerData.swift",
  reactions: "apple/InlineUI/Sources/ReactionPickerEmojis/ReactionPickerEmojis.swift",
} as const

export type SwiftSources = { readonly [K in keyof typeof SWIFT_SOURCES]: string }

export const readSwiftSources = (repoRoot: string): SwiftSources => ({
  data: readFileSync(join(repoRoot, SWIFT_SOURCES.data), "utf8"),
  aliases: readFileSync(join(repoRoot, SWIFT_SOURCES.aliases), "utf8"),
  pickerData: readFileSync(join(repoRoot, SWIFT_SOURCES.pickerData), "utf8"),
  reactions: readFileSync(join(repoRoot, SWIFT_SOURCES.reactions), "utf8"),
})

/** A Swift string literal's body to its value (`\u{...}`, `\"`, `\\`, `\n`, `\t`). */
const unescapeSwift = (body: string): string =>
  body.replace(/\\(u\{([0-9a-fA-F]+)\}|.)/g, (_match, escape: string, hex: string | undefined) => {
    if (hex !== undefined) return String.fromCodePoint(Number.parseInt(hex, 16))
    switch (escape) {
      case "n":
        return "\n"
      case "t":
        return "\t"
      case "0":
        return "\0"
      default:
        return escape
    }
  })

/** Every `"..."` literal in a piece of Swift, in order. */
export const stringLiterals = (swift: string): string[] => {
  const out: string[] = []
  for (const match of swift.matchAll(/"((?:[^"\\\n]|\\.)*)"/g)) out.push(unescapeSwift(match[1] ?? ""))
  return out
}

/** The text between `start` (inclusive of nothing) and the first `end` after it. */
const between = (source: string, start: string, end: string, file: string): string => {
  const from = source.indexOf(start)
  if (from < 0) throw new Error(`${file}: "${start}" not found`)
  const to = source.indexOf(end, from + start.length)
  if (to < 0) throw new Error(`${file}: end of "${start}" not found`)
  return source.slice(from + start.length, to)
}

/** One row of `EmojiAutocompleteData.rawEntries`: emoji, shortcode, label, CLDR keywords. */
export type RawEmojiRow = { emoji: string; shortcode: string; label: string; keywords: string[] }

/** `EmojiAutocompleteData.rawEntries` (a multi-line string literal of tab-separated rows). */
export const parseRawEntries = (swift: string): RawEmojiRow[] => {
  const body = between(swift, 'static let rawEntries = """\n', '\n"""', SWIFT_SOURCES.data)
  return body.split("\n").map((line, index) => {
    const parts = line.split("\t")
    if (parts.length !== 3 && parts.length !== 4) throw new Error(`${SWIFT_SOURCES.data}: invalid row ${index + 1}: ${line}`)
    const [emoji = "", shortcode = "", label = "", keywords = ""] = parts
    return { emoji, shortcode, label, keywords: parts.length === 4 ? keywords.split(",") : [] }
  })
}

/** `EmojiAutocompleteAliases.keywordsByShortcode`: one `"shortcode": ["alias", ...],` per line. */
export const parseAliases = (swift: string): Map<string, string[]> => {
  const body = between(swift, "static let keywordsByShortcode: [String: [String]] = [", "\n  ]\n", SWIFT_SOURCES.aliases)
  const out = new Map<string, string[]>()
  for (const line of body.split("\n")) {
    const match = /^\s*"((?:[^"\\]|\\.)*)":\s*\[(.*)\],?\s*$/.exec(line)
    if (!match) {
      if (line.trim() === "" || line.trim().startsWith("//")) continue
      throw new Error(`${SWIFT_SOURCES.aliases}: unreadable alias line: ${line}`)
    }
    const key = unescapeSwift(match[1] ?? "")
    if (out.has(key)) throw new Error(`${SWIFT_SOURCES.aliases}: duplicate key ${key}`)
    out.set(key, stringLiterals(match[2] ?? ""))
  }
  return out
}

/** `EmojiAutocompletePopularity.ranked`. */
export const parsePopularity = (swift: string): string[] =>
  stringLiterals(between(swift, "static let ranked: [String] = [", "\n  ]", SWIFT_SOURCES.aliases))

/** `EmojiPickerData.sectionBoundaries`: id, title and the shortcode of each section's first emoji. */
export const parseSectionBoundaries = (swift: string): { id: string; title: string; firstShortcode: string }[] => {
  const body = between(swift, "private static let sectionBoundaries: [SectionBoundary] = [", "\n  ]", SWIFT_SOURCES.pickerData)
  const out: { id: string; title: string; firstShortcode: string }[] = []
  for (const match of body.matchAll(/SectionBoundary\(id: "([^"]*)", title: "([^"]*)", firstShortcode: "([^"]*)"\)/g)) {
    out.push({ id: match[1] ?? "", title: unescapeSwift(match[2] ?? ""), firstShortcode: match[3] ?? "" })
  }
  if (out.length === 0) throw new Error(`${SWIFT_SOURCES.pickerData}: no section boundaries`)
  return out
}

/** `ReactionPickerEmojis.defaultEmojis`, the quick reaction set. */
export const parseQuickReactions = (swift: string): string[] =>
  stringLiterals(between(swift, "public static let defaultEmojis: [String] = [", "\n  ]", SWIFT_SOURCES.reactions))

/** `ReactionPickerEmojis.legacyAcknowledgementEmojis`, never offered as quick reactions. */
export const parseLegacyAcknowledgements = (swift: string): string[] =>
  stringLiterals(between(swift, "legacyAcknowledgementEmojis: Set<String> = [", "]", SWIFT_SOURCES.reactions))
