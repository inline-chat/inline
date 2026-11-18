import { describe, expect, it } from "vitest"
import { MatchTier, compareMatches, matchFields, matchText, normalizeText, prepareField, prepareQuery, type Match } from "./match"

const highlighted = (text: string, match: Match | undefined): string[] =>
  (match?.ranges ?? []).map(([start, end]) => text.slice(start, end))

describe("normalizeText", () => {
  it.each([
    ["Café au Lait", "cafe au lait"],
    ["Cafe\u0301", "cafe"],
    ["  Hello,   World!  ", "hello world"],
    ["İstanbul", "istanbul"],
    ["ＡＢＣ１２", "abc12"],
    ["ﬁle", "file"],
    ["مُحَمَّد", "محمد"],
    ["كيك", "کیک"],
    ["علي", "علی"],
    ["می\u200Cخواهم", "میخواهم"],
    ["کت\u0640\u0640\u0640اب", "کتاب"],
    ["۱۲۳ ٤٥", "123 45"],
    ["\u200FHello\u200E", "hello"],
    ["👍🏽 ok", "👍 ok"],
    ["", ""],
    ["!!!", ""],
  ])("%j → %j", (input, expected) => {
    expect(normalizeText(input)).toBe(expected)
  })
})

describe("prepareQuery", () => {
  it("is undefined for a query without word characters", () => {
    expect(prepareQuery("")).toBeUndefined()
    expect(prepareQuery("  ,. ")).toBeUndefined()
  })

  it("splits words and keeps a compact form", () => {
    expect(prepareQuery("  Product   Meet ")).toMatchObject({ normalized: "product meet", compact: "productmeet", tokens: ["product", "meet"] })
  })
})

describe("match tiers", () => {
  it.each([
    ["anna", "Anna", MatchTier.exact],
    ["ann", "Anna Smith", MatchTier.fieldPrefix],
    ["smi", "Anna Smith", MatchTier.tokenPrefix],
    ["smi an", "Anna Smith", MatchTier.tokenPrefix],
    ["pm", "Product Meeting", MatchTier.acronym],
    ["wpm", "Weekly Product Meeting", MatchTier.acronym],
    ["nna", "Anna Smith", MatchTier.substring],
    ["johnd", "John Doe", MatchTier.compact],
    ["pdmg", "Product Meeting", MatchTier.fuzzy],
  ])("%j in %j", (query, text, tier) => {
    expect(matchText(query, text)?.tier).toBe(tier)
  })

  it.each([
    ["xyz", "Anna"],
    ["pd", "Product Meeting"], // two letters never match fuzzily
    ["an", ""],
    ["", "Anna"],
  ])("%j does not match %j", (query, text) => {
    expect(matchText(query, text)).toBeUndefined()
  })

  it("does not match fuzzily across a long field (Mac rule)", () => {
    expect(matchText("pdg", "p d g")?.tier).toBe(MatchTier.acronym)
    expect(matchText("pxg", `p${"a".repeat(40)}x g`)).toBeUndefined()
  })

  it("ranks prefix over word start over mid-word", () => {
    const prefix = matchText("ann", "Annabel")
    const word = matchText("ann", "Bob Annex")
    const mid = matchText("ann", "Joanna")
    expect(prefix && word && mid).toBeTruthy()
    if (!prefix || !word || !mid) return
    expect(prefix.score).toBeGreaterThan(word.score)
    expect(word.score).toBeGreaterThan(mid.score)
    expect([mid, prefix, word].sort(compareMatches)).toEqual([prefix, word, mid])
  })

  it("prefers the higher priority field, then the earlier word, then the shorter field", () => {
    const query = prepareQuery("al")
    if (!query) throw new Error("query")
    const title = prepareField("Alice", 400)
    const username = prepareField("alice", 500)
    if (!title || !username) throw new Error("fields")
    expect(matchFields(query, [title, username])?.fieldIndex).toBe(1)
    const early = matchText("al", "Al Bob")
    const late = matchText("al", "Bob Al")
    if (!early || !late) throw new Error("match")
    expect(compareMatches(early, late)).toBeLessThan(0)
    const short = matchText("al", "Al")
    const long = matchText("al", "Alexandra")
    if (!short || !long) throw new Error("match")
    expect(compareMatches(short, long)).toBeLessThan(0)
  })

  it("needs a separate word for each repeated query word", () => {
    expect(matchText("an an", "Anna Andrews")?.ranges).toEqual([
      [0, 2],
      [5, 7],
    ])
  })
})

describe("highlight ranges", () => {
  it.each<[string, string, string[]]>([
    ["cafe", "Café Nero", ["Café"]],
    ["cafe", "Cafe\u0301 Nero", ["Cafe\u0301"]],
    ["pm", "Product Meeting", ["P", "M"]],
    ["meet prod", "Product Meeting", ["Prod", "Meet"]],
    ["johnd", "John Doe", ["John", "D"]],
    ["pdmg", "Product Meeting", ["P", "d", "M", "g"]],
    ["launch", "🚀 Launch", ["Launch"]],
    ["🚀", "🚀 Launch", ["🚀"]],
    ["istanbul", "İstanbul", ["İstanbul"]],
    ["abc", "ＡＢＣ", ["ＡＢＣ"]],
  ])("%j in %j", (query, text, expected) => {
    expect(highlighted(text, matchText(query, text))).toEqual(expected)
  })

  it("maps right-to-left and mixed-script text to original offsets", () => {
    const text = "Project پروژه"
    const match = matchText("پرو", text)
    expect(match?.tier).toBe(MatchTier.tokenPrefix)
    expect(match?.ranges).toEqual([[8, 11]])
    expect(highlighted(text, match)).toEqual(["پرو"])
  })

  it("folds Arabic and Persian letter variants both ways", () => {
    expect(matchText("كيان", "کیان")?.tier).toBe(MatchTier.exact)
    expect(matchText("کیان", "كيان")?.tier).toBe(MatchTier.exact)
    expect(matchText("علی", "علي رضا")?.tier).toBe(MatchTier.fieldPrefix)
  })

  it("ignores the zero-width non-joiner and keeps it inside the highlight", () => {
    const text = "می\u200Cخواهم بروم"
    const match = matchText("میخواهم", text)
    expect(match?.tier).toBe(MatchTier.fieldPrefix)
    expect(highlighted(text, match)).toEqual(["می\u200Cخواهم"])
  })

  it("matches Arabic text with or without harakat", () => {
    const text = "مُحَمَّد علي"
    const match = matchText("محمد", text)
    expect(match?.tier).toBe(MatchTier.fieldPrefix)
    expect(highlighted(text, match)).toEqual(["مُحَمَّد"])
  })

  it("matches Persian digits to ASCII digits", () => {
    expect(matchText("2026", "Plan ۲۰۲۶")?.tier).toBe(MatchTier.tokenPrefix)
  })

  it("matches emoji with skin tones and inside ZWJ sequences", () => {
    expect(matchText("👍", "👍🏽 Approved")?.tier).toBe(MatchTier.fieldPrefix)
    expect(matchText("approved", "👍🏽 Approved")?.ranges).toEqual([[5, 13]])
  })
})

describe("robustness", () => {
  it("never throws, whatever the input", () => {
    let seed = 42
    const random = () => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff
      return seed / 0x7fffffff
    }
    const pool = ["a", "Z", " ", "-", "é", "\u0301", "\u200C", "ك", "ی", "🚀", "🏽", "\uD800", "\uDC00", "\u0000", "ﷺ", "İ", "ß", "\u202E", "١"]
    const randomText = () => Array.from({ length: Math.floor(random() * 12) }, () => pool[Math.floor(random() * pool.length)]).join("")
    for (let i = 0; i < 3000; i++) {
      const query = randomText()
      const text = randomText()
      const match = matchText(query, text)
      if (match) {
        for (const [start, end] of match.ranges) {
          expect(start).toBeGreaterThanOrEqual(0)
          expect(end).toBeLessThanOrEqual(text.length)
          expect(end).toBeGreaterThan(start)
        }
      }
    }
    expect(() => matchText(undefined as unknown as string, 5 as unknown as string)).not.toThrow()
    expect(prepareField(null, 1)).toBeUndefined()
    expect(normalizeText({} as unknown as string)).toBe("")
  })
})

describe("performance", () => {
  it("scores 10,000 candidates well within budget", () => {
    const first = ["Anna", "Bob", "Carlos", "Dana", "Émile", "Farhad", "علی", "Grace", "Hiro", "Ines"]
    const last = ["Smith", "Lovelace", "Rossi", "Kim", "Moreau", "Karimi", "رضایی", "Hopper", "Tanaka", "Silva"]
    const words = ["Product", "Meeting", "Design", "Launch", "Roadmap", "Hiring", "Infra", "پروژه", "Weekly", "Notes"]
    const prepareStart = performance.now()
    const candidates = Array.from({ length: 10_000 }, (_, i) => {
      const title =
        i % 2 === 0
          ? `${first[i % 10]} ${last[Math.floor(i / 10) % 10]}`
          : `${words[i % 10]} ${words[Math.floor(i / 10) % 10]} ${i}`
      return [prepareField(title, 400), prepareField(`user${i}`, 500), prepareField("Engineering", 100)].filter(
        (field) => field !== undefined,
      )
    })
    const prepareMs = performance.now() - prepareStart

    const queries = ["a", "an", "pm", "prod meet", "karimi", "zzzz", "پرو", "wkly"]
    const matchStart = performance.now()
    let matched = 0
    for (const raw of queries) {
      const query = prepareQuery(raw)
      if (!query) continue
      for (const fields of candidates) if (matchFields(query, fields)) matched++
    }
    const perQueryMs = (performance.now() - matchStart) / queries.length

    expect(matched).toBeGreaterThan(0)
    // Generous bounds for a loaded CI machine; typical is a few ms per query.
    expect(prepareMs).toBeLessThan(1_500)
    expect(perQueryMs).toBeLessThan(150)
  })
})
