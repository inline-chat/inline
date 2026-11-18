/**
 * The search engine against the Mac's ranking. Every case is one of the Mac's
 * own tests (`apple/InlineUI/Tests/InlineUITests/EmojiAutocompleteTests.swift`)
 * or a rule of `EmojiAutocomplete.swift`; line numbers refer to that file.
 */

import { describe, expect, it } from "vitest"
import { createEmojiEngine, usageBoost, type UsageScores } from "./engine"
import { normalize } from "./normalize"
import { containsSkinTone, usageKey } from "./tone"

const engine = createEmojiEngine()
const search = (query: string, limit = 8, usage?: UsageScores) => engine.search(query, { limit, ...(usage ? { usage } : {}) })
const emojis = (query: string, limit = 8, usage?: UsageScores) => search(query, limit, usage).map((item) => item.emoji)
const first = (query: string, limit = 8, usage?: UsageScores) => search(query, limit, usage)[0]
const scores = (map: Record<string, number>): UsageScores => {
  const byKey = new Map(Object.entries(map).map(([emoji, score]) => [usageKey(emoji), score]))
  return { score: (key) => byKey.get(key) ?? 0 }
}

describe("normalize (lines 323-347)", () => {
  it("folds case and diacritics and joins separators into one underscore", () => {
    expect(normalize("Face-Palm")).toBe("face_palm")
    expect(normalize("  face   palm  ")).toBe("face_palm")
    expect(normalize("Piñata")).toBe("pinata")
    expect(normalize("flag: Türkiye")).toBe("flag_turkiye")
    expect(normalize(":tada")).toBe("tada")
    expect(normalize("U.S. Virgin Islands")).toBe("u_s_virgin_islands")
  })

  it("keeps a sign before a digit at the start of a word", () => {
    expect(normalize("+1")).toBe("+1")
    expect(normalize("-1")).toBe("-1")
    expect(normalize("x-ray")).toBe("x_ray")
    expect(normalize("+")).toBe("+")
    expect(normalize("a+b")).toBe("ab")
  })

  it("drops anything else", () => {
    expect(normalize("man's")).toBe("mans")
    expect(normalize("🎉")).toBe("")
    expect(normalize("___")).toBe("")
  })
})

// Each row: query, limit, the expected first emoji (or shortcode), and the Mac test it comes from.
const firstResults: readonly (readonly [query: string, emoji: string, source: string])[] = [
  ["sm", "😄", "twoCharacterQueriesCompleteShortcodes: 'sm' completes shortcodes, popular first"],
  ["he", "❤️", "twoCharacterQueriesCompleteShortcodes"],
  ["th", "👍", "twoCharacterQueriesCompleteShortcodes"],
  ["hea", "❤️", "popularEmojiLeadPrefixMatches: popularity lifts within a tier (line 273)"],
  ["lau", "😂", "popularEmojiLeadPrefixMatches"],
  ["hash", "#️⃣", "baseEntriesHaveUniqueShortcodes: keycap shortcode override (Aliases lines 310-317)"],
  ["dark_sunglasses", "🕶️", "baseEntriesHaveUniqueShortcodes: sunglasses override (Aliases line 294)"],
  ["o", "😮", "allowsOneCharacterExactMatches: one character matches exact aliases only (line 359)"],
  ["tm", "™️", "prioritizesTrademarkAliasOverFlagKeyword: exact alias (3) beats exact keyword (14)"],
  ["x", "❌", "allowsExactXShortcode"],
  ["smile", "😄", "prioritizesCommonShortcodeAliases: exact shortcode is tier 0"],
  ["us", "🇺🇸", "showsTwoLetterFlagAliases"],
  ["lol", "😂", "matchesCommonSlangAliases"],
  ["lmfao", "😂", "matchesStrongerChatSlangAliases"],
  ["mindblown", "🤯", "matchesCompactUnderscoreFreeAliases: compact terms (line 369)"],
  ["red heart", "❤️", "matchesMultiWordQueriesInAnyOrder (lines 393-414)"],
  ["heart red", "❤️", "matchesMultiWordQueriesInAnyOrder"],
  ["face_palm", "🤦", "treatsSeparatorsAlike"],
  ["face palm", "🤦", "treatsSeparatorsAlike"],
  ["face-palm", "🤦", "treatsSeparatorsAlike"],
  ["facepalm", "🤦", "treatsSeparatorsAlike"],
  ["thumsup", "👍", "toleratesOneTypo: a missing letter (lines 421-485)"],
  ["hart", "❤️", "toleratesOneTypo"],
  ["rocekt", "🚀", "toleratesOneTypo: an adjacent swap"],
  ["celebrte", "🎉", "toleratesOneTypo"],
  ["pray", "🙏", "keepsShortTypoMatchesOut"],
  ["point_right", "👉", "matchesCommonSlackShortcodes"],
  ["zap", "⚡", "matchesCommonSlackShortcodes"],
  ["heavy_check_mark", "✔️", "matchesCommonSlackShortcodes"],
  ["party", "🎉", "personalUsageLiftsMatches: without usage"],
  ["+1", "👍", "supportsPlusAndMinusAliases"],
  ["-1", "👎", "supportsPlusAndMinusAliases"],
  [":tada", "🎉", "pickerDataUsesAutocompleteSearch: a leading colon is a separator"],
]

describe("search: the Mac's results", () => {
  it.each(firstResults)("%s ranks %s first (%s)", (query, emoji) => {
    expect(first(query, 24)?.emoji).toBe(emoji)
  })

  it("two-letter queries complete shortcodes only, not alias or keyword prefixes (line 367)", () => {
    expect(emojis("sm", 20)).toContain(engine.lookup("🇸🇲")?.emoji)
    expect(search("sm", 20).some((item) => item.shortcode === "flag_san_marino")).toBe(true)
    // "he" prefixes the "hehe" alias of 😂.
    expect(emojis("he", 24)).not.toContain("😂")
  })

  it("a one-character query does not match keyword prefixes (lines 358-363)", () => {
    expect(search("o", 5).map((item) => item.shortcode)).not.toContain("hollow_red_circle")
    expect(first("o", 5)?.shortcode).toBe("face_with_open_mouth")
  })

  it("two-character exact words and aliases match (allowsTwoCharacterExactMatches)", () => {
    const result = emojis("no", 10)
    for (const emoji of ["🙅‍♂️", "🙅‍♀️", "🚫", "🇳🇴", "👎"]) expect(result).toContain(emoji)
  })

  it("flag aliases: every 'us' result is a flag (showsTwoLetterFlagAliases)", () => {
    expect(search("us", 5).every((item) => item.shortcode.startsWith("flag_"))).toBe(true)
  })

  it("cat smile finds the smirking cat (matchesMultiWordQueriesInAnyOrder)", () => {
    expect(emojis("cat smile", 8)).toContain("😼")
  })

  it("weak tiers stay out when strict matches are plenty (lines 287-306, keepsShortTypoMatchesOut)", () => {
    expect(emojis("pray", 24)).not.toContain("▶️")
    expect(new Set(emojis("lgtm", 24))).toEqual(new Set(["👍", "✅"]))
  })

  it("finds CLDR keyword matches (findsCLDRKeywordMatches)", () => {
    expect(emojis("rocket", 5)).toContain("🚀")
  })

  it("excludes skin tone variants (searchExcludesSkinToneVariants)", () => {
    for (const query of ["wave", "thumbs", "ok_hand", "shrug", "facepalm"]) {
      const result = emojis(query, 24)
      expect(result.length).toBeGreaterThan(0)
      expect(result.some(containsSkinTone)).toBe(false)
    }
  })

  it("rebuilds accented shortcodes from labels (baseEntriesHaveUniqueShortcodes, Aliases lines 300-307)", () => {
    expect(first("pinata", 1)?.shortcode).toBe("pinata")
    expect(engine.all.some((item) => item.shortcode === "flag_turkiye")).toBe(true)
  })

  it("an empty or punctuation-only query, or a zero limit, finds nothing (line 264)", () => {
    expect(search("")).toEqual([])
    expect(search("::")).toEqual([])
    expect(search("smile", 0)).toEqual([])
  })

  it("equal scores break by shorter shortcode, then table order (lines 308-315)", () => {
    // Capped tightness (6) makes these long country shortcodes tie on score; neither has aliases or popularity.
    const names = search("flag_s", 60).map((item) => item.shortcode)
    const a = names.indexOf("flag_st_vincent_and_grenadines")
    const b = names.indexOf("flag_south_georgia_and_south_sandwich_islands")
    expect(a).toBeGreaterThanOrEqual(0)
    expect(b).toBeGreaterThan(a)
  })

  it("limits results and never depends on the limit for order", () => {
    const long = search("face", 50).map((item) => item.emoji)
    const short = search("face", 8).map((item) => item.emoji)
    expect(short).toEqual(long.slice(0, 8))
  })
})

describe("search: personal usage (lines 157-175, 273)", () => {
  it("lifts a match, but not over another emoji's exact shortcode (personalUsageLiftsMatches)", () => {
    const usage = scores({ "🥳": 40 })
    expect(first("party", 3, usage)?.emoji).toBe("🥳")
    expect(first("tada", 3, usage)?.emoji).toBe("🎉")
  })

  it("is capped at 7 and grows with log2", () => {
    expect(usageBoost(0)).toBe(0)
    expect(usageBoost(-1)).toBe(0)
    expect(usageBoost(1)).toBe(3)
    expect(usageBoost(1000)).toBe(7)
  })

  it("ignores skin tone and VS16 in usage keys", () => {
    const usage = scores({ "👋🏽": 40 })
    expect(usage.score(usageKey("👋"))).toBe(40)
  })
})

describe("lookup and tones", () => {
  it("finds the dataset entry ignoring tone and VS16 (suggestion(forEmoji:))", () => {
    expect(engine.lookup("👋🏿")?.shortcode).toBe("wave")
    expect(engine.lookup("❤")?.emoji).toBe("❤️")
    expect(engine.lookup("not an emoji")).toBeUndefined()
  })

  it("applies the preferred tone (preferredSkinToneResolvesSupportedEmojiVariants)", () => {
    expect(engine.withTone("👋", "light")).toBe("👋🏻")
    expect(engine.withTone("🧑‍💻", "dark")).toBe("🧑🏿‍💻")
    expect(engine.withTone("👋", "medium")).toBe("👋🏽")
  })

  it("keeps explicit tones, unsupported emoji and standard mode (preferredSkinTonePreserves...)", () => {
    expect(engine.withTone("👋🏻", "medium")).toBe("👋🏻")
    expect(engine.withTone("🚀", "dark")).toBe("🚀")
    expect(engine.withTone("👋🏽", "standard")).toBe("👋🏽")
  })

  it("tones emoji with VS16 and multi-person sequences (the Mac misses the VS16 ones, see README)", () => {
    expect(engine.withTone("☝️", "dark")).toBe("☝🏿")
    expect(engine.withTone("🕵️‍♂️", "medium")).toBe("🕵🏽‍♂️")
    expect(engine.withTone("🧑‍🤝‍🧑", "mediumLight")).toBe("🧑🏼‍🤝‍🧑🏼")
  })
})
