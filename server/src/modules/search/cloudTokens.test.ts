import { describe, expect, test } from "bun:test"
import { randomBytes } from "node:crypto"
import { cloudDocumentTags, cloudQueryTags, matchExcerpts, parseCloudQuery } from "./cloudTokens"

describe("whole-word search profile", () => {
  test("Arabic and Persian keyboard spellings, canonical composition, and intentional distinctions", () => {
    const pairs: [string, string, boolean][] = [
      ["تقرير", "تَقْرِير", true],
      ["إرسال", "ارسال", true],
      ["كتاب", "کتاب", true],
      ["٢٠٢٦", "۲۰۲۶", true],
      ["۲۰۲۶", "2026", true],
      ["عَلَم", "عِلْم", true],
      ["مدرسة", "مدرسه", false],
      ["على", "علي", false],
      ["می‌روم", "می روم", false],
      ["café", "cafe\u0301", true],
      ["café", "cafe", false],
      ["كتاب", "الكتاب", false],
      ["deploy", "deployment", false],
      ["ploy", "deployment", false],
    ]
    for (const [query, text, expected] of pairs) {
      expect(Boolean(matchExcerpts(parseCloudQuery(query), { text }))).toBe(expected)
    }
  })

  test("filenames, repeated phrase words, original UTF-16 offsets and bounded excerpts", () => {
    const match = matchExcerpts(parseCloudQuery('"plan plan" pdf'), { text: "📝 PLAN plan", fileName: "a.pdf" })
    expect(match?.[0]?.highlights).toEqual([
      { offset: 3, length: 4 },
      { offset: 8, length: 4 },
    ])
    expect(matchExcerpts(parseCloudQuery('"plan plan"'), { text: "plan", fileName: "plan.pdf" })).toBeUndefined()
    const decorated = "ع" + "ـ".repeat(3000) + "لم"
    const excerpt = matchExcerpts(parseCloudQuery("علم"), { text: decorated })?.[0]
    expect(excerpt!.text.length).toBeLessThanOrEqual(257)
    expect(excerpt!.highlights[0]!.length).toBe(excerpt!.text.length)
  })

  test("product profile golden tokens, stored tag and display offsets across runtime upgrades", () => {
    const source = "📝 تَقْرِير_۲۰۲۶-cafe\u0301.pdf"
    expect(parseCloudQuery(source)).toEqual([["تقرير", "2026", "café", "pdf"]])
    expect(cloudQueryTags(42, Buffer.alloc(32), [["تقرير"]])[0]![0]).toBe("79a1ffd1-2c1d-1c27-6b47-bb362fd26a24")
    expect(matchExcerpts(parseCloudQuery("تقرير 2026 café pdf"), { fileName: source })![0]!.highlights).toEqual([
      { offset: 3, length: 8 },
      { offset: 12, length: 4 },
      { offset: 17, length: 5 },
      { offset: 23, length: 3 },
    ])
  })

  test("punctuation-connected components match consecutively in one field", () => {
    for (const example of ["3.14", "mo@inline.chat", "release_plan", "v2.1"]) {
      const query = parseCloudQuery(example)
      expect(matchExcerpts(query, { fileName: example })).toBeDefined()
      const words = query[0]!
      expect(matchExcerpts(query, { text: words.join(" unrelated ") })).toBeUndefined()
      expect(matchExcerpts(query, { text: words[0], fileName: words.slice(1).join(" ") })).toBeUndefined()
    }
    expect(matchExcerpts(parseCloudQuery("release plan"), { text: "release", fileName: "plan" })).toBeDefined()
  })

  test("one 128-bit tag per distinct word and field, equality only within its domain", () => {
    const key = randomBytes(32)
    const tags = cloudDocumentTags(1, key, { text: "file FILE", fileName: "file.pdf" }, 3)!
    expect(new Set(tags).size).toBe(3)
    expect(tags).toContain(cloudQueryTags(1, key, parseCloudQuery("file"))[0]![0]!)
    expect(tags).not.toContain(cloudQueryTags(2, key, parseCloudQuery("file"))[0]![0]!)
    expect(tags).not.toContain(cloudQueryTags(1, key, parseCloudQuery("fil"))[0]![0]!)
    expect(cloudDocumentTags(1, key, { text: "a b c" }, 2)).toBeNull()
    for (const term of ["", '""', '"unfinished', "dep*", "a b c d e f g h i", "é".repeat(257)]) {
      expect(() => parseCloudQuery(term)).toThrow()
    }
  })
})
