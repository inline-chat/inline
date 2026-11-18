import { describe, expect, it } from "vitest"
import { matchRanges, messageSnippet } from "../highlight"
import { indexText, tokenize } from "../normalize"
import { isSearchableQuery, matchExpression, parseQuery } from "../query"

const highlighted = (text: string, query: string) =>
  (matchRanges(text, parseQuery(query)!) ?? []).map(([start, end]) => text.slice(start, end))

describe("folding and tokens", () => {
  it("folds case, diacritics and punctuation like the Quick Search matcher", () => {
    expect(indexText("Café NAÏVE, déjà-vu!")).toBe("cafe naive deja vu")
    expect(indexText("Ｆｕｌｌ ｗｉｄｔｈ ﬁle")).toBe("full width file")
  })

  it("folds Persian and Arabic variants, diacritics, tatweel, digits and the zero-width non-joiner", () => {
    // Arabic kaf and yeh, Persian keheh and Farsi yeh, all one form.
    expect(indexText("كتاب يك")).toBe(indexText("کتاب یک"))
    // Harakat are dropped.
    expect(indexText("مَرْحَبًا")).toBe(indexText("مرحبا"))
    // Tatweel is dropped.
    expect(indexText("مـــرحبا")).toBe(indexText("مرحبا"))
    // A ZWNJ joins: with and without it is one word.
    expect(indexText("می‌خواهم")).toBe(indexText("میخواهم"))
    expect(indexText("۱۲۳ ١٢٣")).toBe("123 123")
    // Teh marbuta and alef with hamza.
    expect(indexText("مدرسة أحمد")).toBe(indexText("مدرسه احمد"))
  })

  it("splits scripts written without spaces and pictographs into one token per character", () => {
    expect(indexText("東京タワーに行きました")).toBe("東 京 タ ワ ー に 行 き ま し た")
    expect(indexText("我们发布")).toBe("我 们 发 布")
    expect(indexText("회의를 시작")).toBe("회 의 를 시 작")
    expect(indexText("ship🚀it 👍🏽")).toBe("ship 🚀 it 👍")
    const tokens = tokenize("ship🚀it")
    expect(tokens.map((token) => token.joined)).toEqual([false, true, true])
  })

  it("never throws on hostile input", () => {
    for (const input of [undefined, null, 42, {}, "", "\uD800", "a\uDC00b", "\u0000\u0001", "‌‍", "x".repeat(70_000)]) {
      expect(() => indexText(input)).not.toThrow()
      expect(() => tokenize(input, { withUnits: true })).not.toThrow()
    }
    expect(indexText("x".repeat(70_000)).length).toBe(32_768)
  })
})

describe("query language", () => {
  it("needs two letters or digits, like the Mac", () => {
    expect(isSearchableQuery("a")).toBe(false)
    expect(isSearchableQuery("🚀🚀")).toBe(false)
    expect(isSearchableQuery("ab")).toBe(true)
    expect(parseQuery(" . ")).toBeUndefined()
  })

  it("makes every unquoted word a prefix and a quoted run a phrase", () => {
    expect(parseQuery("proj meet")!.expression).toBe('"proj" * AND "meet" *')
    expect(parseQuery('say "deploy now" ok')!.expression).toBe('"say" * AND "deploy now" AND "ok" *')
    // An unclosed quote is a phrase being typed: its last word is a prefix.
    expect(parseQuery('"deploy no')!.expression).toBe('"deploy no" *')
    // One letter matches only itself.
    expect(parseQuery("deploy t")!.expression).toBe('"deploy" * AND "t"')
    // Characters with no separator are a phrase; a unigram is never a prefix.
    expect(parseQuery("東京")!.expression).toBe('"東 京"')
    expect(parseQuery("hello🎉world")!.expression).toBe('"hello 🎉 world" *')
  })

  it("turns FTS5 syntax into plain words", () => {
    expect(parseQuery("NEAR(a b) AND foo:bar -baz *qux")!.expression).toBe(
      '"near" * AND "a" AND "b" AND "and" * AND "foo" * AND "bar" * AND "baz" * AND "qux" *',
    )
    expect(matchExpression(parseQuery("hi there")!, "c42")).toBe('body : ("hi" * AND "there" *) AND chat : "c42"')
  })
})

describe("ranges", () => {
  it("are UTF-16 offsets into the original text, merged, with prefixes cut at the typed length", () => {
    expect(highlighted("Deploying the café today", "dep caf")).toEqual(["Dep", "caf"])
    expect(highlighted("x 👍🏽 thanks", "👍 thanks")).toEqual(["👍🏽", "thanks"])
    // A decomposed accent belongs to its letter.
    expect(highlighted("café now", "café")).toEqual(["café"])
    // A ZWNJ inside a word is inside its highlight.
    expect(highlighted("من می‌خواهم بروم", "میخواهم")).toEqual(["می‌خواهم"])
    expect(highlighted("東京タワーに行きました", "タワー")).toEqual(["タワー"])
    expect(highlighted('He said "ship it"', '"ship it"')).toEqual(["ship it"])
  })

  it("are undefined when a phrase does not occur", () => {
    expect(matchRanges("deploy now", parseQuery("deploy later")!)).toBeUndefined()
  })

  it("map into a snippet that collapses whitespace and cuts with ellipses", () => {
    const text = `${"lorem ".repeat(30)}the   target\n\nword ${"ipsum ".repeat(30)}`
    const ranges = matchRanges(text, parseQuery("target")!)!
    const { snippet, ranges: inSnippet } = messageSnippet(text, ranges)
    expect(snippet.startsWith("...")).toBe(true)
    expect(snippet.endsWith("...")).toBe(true)
    expect(snippet).toContain("the target word")
    expect(inSnippet.map(([start, end]) => snippet.slice(start, end))).toEqual(["target"])
  })
})
