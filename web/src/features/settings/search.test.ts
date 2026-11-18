import { describe, expect, it } from "vitest"
import { resolvePage, SETTINGS_ITEMS, SETTINGS_PAGES, visiblePages } from "./catalog"
import { buildSearchIndex, foldText, pagesWithResults, searchSettings, searchWords } from "./search"

const index = buildSearchIndex(SETTINGS_PAGES, SETTINGS_ITEMS)
const ids = (query: string, entries = index) => searchSettings(query, entries).map((entry) => entry.id)

describe("catalog", () => {
  it("has unique item IDs, each on a listed page", () => {
    const seen = new Set<string>()
    for (const spec of SETTINGS_ITEMS) {
      expect(seen.has(spec.id)).toBe(false)
      seen.add(spec.id)
      expect(SETTINGS_PAGES.some((page) => page.id === spec.page)).toBe(true)
    }
  })

  it("resolves the destination's page", () => {
    const pages = visiblePages({ hasAccount: true })
    expect(resolvePage(undefined, pages)).toEqual({ kind: "page", id: "general" })
    expect(resolvePage("appearance", pages)).toEqual({ kind: "page", id: "appearance" })
    expect(resolvePage("privacy", pages)).toEqual({ kind: "unavailable", page: "privacy", title: "Privacy" })
    expect(resolvePage("account", visiblePages({ hasAccount: false }))).toEqual({
      kind: "unavailable",
      page: "account",
      title: "Account",
    })
  })

  it("lists Account only with an account, in Mac order", () => {
    expect(visiblePages({ hasAccount: true }).map((page) => page.id)).toEqual([
      "account",
      "general",
      "appearance",
      "notifications",
      "data",
      "hotkeys",
      "updates",
    ])
    expect(visiblePages({ hasAccount: false })[0]?.id).toBe("general")
  })
})

describe("search", () => {
  it("folds case, diacritics and width", () => {
    expect(foldText("Thème ＡＢＣ")).toBe("theme abc")
    expect(searchWords("Check-Spelling, while typing!")).toEqual(["check", "spelling", "while", "typing"])
  })

  it("matches nothing for an empty or punctuation-only query", () => {
    expect(ids("")).toEqual([])
    expect(ids("  -- ")).toEqual([])
  })

  it("ranks a title prefix over a title word over a keyword over context", () => {
    expect(ids("theme")).toEqual(["theme"])
    // "spacing": title word of Line Spacing, keyword of nothing else.
    expect(ids("spacing")).toEqual(["lineSpacing"])
    // "dark": keyword of Appearance only.
    expect(ids("dark")).toEqual(["appearance"])
    // "appearance": title prefix of the Appearance row first, then the rest of the page by context.
    const appearance = ids("appearance")
    expect(appearance[0]).toBe("appearance")
    expect(appearance).toContain("unreadBadgeStyle")
  })

  it("requires every word to match, in any field", () => {
    expect(ids("send enter")).toEqual(["sendMessages"])
    expect(ids("send zebra")).toEqual([])
    expect(ids("unread badge")).toEqual(["unreadBadgeStyle", "appBadge"])
  })

  it("prefix-matches words and ignores case and accents", () => {
    expect(ids("SPELL")).toEqual(["checkSpelling"])
    expect(ids("thème")).toEqual(["theme"])
    expect(ids("log")).toContain("thisDevice")
  })

  it("keeps index order for ties", () => {
    // Both are matched only through the "Storage" context.
    const storage = ids("storage")
    expect(storage[0]).toBe("storageUsage")
    expect(storage.slice(1)).toEqual(["persistentStorage", "clearCachedMedia"])
  })

  it("never matches rows of pages that are not listed", () => {
    const withoutAccount = buildSearchIndex(visiblePages({ hasAccount: false }), SETTINGS_ITEMS)
    expect(ids("sign out", withoutAccount)).toEqual([])
    expect(ids("sign out")).toEqual(["thisDevice"])
  })

  it("names the pages that have results, in list order", () => {
    const results = searchSettings("badge", index)
    expect(pagesWithResults(results, SETTINGS_PAGES)).toEqual(["appearance", "notifications"])
  })
})
