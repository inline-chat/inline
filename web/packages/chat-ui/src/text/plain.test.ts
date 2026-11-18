import { describe, expect, it } from "vitest"
import { buildTextDocument } from "./build"
import { firstGrapheme, truncateGraphemes } from "./graphemes"
import { copyText, documentPreview, documentText, previewText } from "./plain"
import type { EntityInput } from "./types"

const e = (type: EntityInput["type"], offset: number, length: number, extra: Partial<EntityInput> = {}): EntityInput =>
  ({ type, offset, length, ...extra }) as EntityInput

describe("previewText", () => {
  it("collapses line breaks and whitespace into one line", () => {
    expect(previewText("  Hello\n\nworld\t again \r\n ")).toBe("Hello world again")
  })

  it("keeps mentions and link labels as they read", () => {
    const text = "@Ada see the docs"
    expect(previewText(text)).toBe("@Ada see the docs")
    const doc = buildTextDocument(text, [e("mention", 0, 4, { userId: "1" as never }), e("textUrl", 13, 4, { url: "https://x.com" })])
    expect(documentPreview(doc)).toBe("@Ada see the docs")
  })

  it("removes control and bidi override characters", () => {
    expect(previewText("a\u0000b\u202ec\u2066d\u0007")).toBe("abcd")
  })

  it("keeps joiners and marks", () => {
    const text = "\u{1F469}\u200d\u{1F4BB} cafe\u0301 \u200f\u0633\u0644\u0627\u0645"
    expect(previewText(text)).toBe(text)
  })

  it("truncates on grapheme boundaries with an ellipsis", () => {
    const family = "\u{1F468}\u200d\u{1F469}\u200d\u{1F467}"
    const text = `${family}${family}${family}${family}`
    expect(previewText(text, { maxGraphemes: 3 })).toBe(`${family}${family}\u2026`)
    expect(previewText("abcdef", { maxGraphemes: 4 })).toBe("abc\u2026")
    expect(previewText("abcd", { maxGraphemes: 4 })).toBe("abcd")
  })

  it("does not leave a space before the ellipsis", () => {
    expect(previewText("abc def ghi", { maxGraphemes: 5 })).toBe("abc\u2026")
  })

  it("uses the fallback for empty text", () => {
    expect(previewText("   \n ", { fallback: "Photo" })).toBe("Photo")
    expect(previewText(undefined)).toBe("")
  })

  it("bounds work on very long text", () => {
    const long = `${"word ".repeat(200_000)}end`
    const preview = previewText(long, { maxGraphemes: 20 })
    expect(preview).toBe(`${"word ".repeat(4).trimEnd()}\u2026`)
  })

  it("marks a cut when whitespace collapsed a long input below the limit", () => {
    const text = `a${" ".repeat(5000)}b`
    expect(previewText(text, { maxGraphemes: 10 })).toBe("a\u2026")
  })
})

describe("truncateGraphemes", () => {
  it("never splits a surrogate pair, combining mark or flag", () => {
    expect(truncateGraphemes("\u{1F600}\u{1F600}\u{1F600}", 2)).toBe("\u{1F600}\u2026")
    expect(truncateGraphemes("e\u0301e\u0301e\u0301", 2)).toBe("e\u0301\u2026")
    expect(truncateGraphemes("\u{1F1E9}\u{1F1EA}\u{1F1EB}\u{1F1F7}x", 2)).toBe("\u{1F1E9}\u{1F1EA}\u2026")
  })

  it("supports no suffix and a zero limit", () => {
    expect(truncateGraphemes("abcdef", 3, "")).toBe("abc")
    expect(truncateGraphemes("abc", 0)).toBe("")
  })

  it("returns text that fits unchanged", () => {
    const text = "e\u0301e\u0301"
    expect(truncateGraphemes(text, 2)).toBe(text)
  })
})

describe("firstGrapheme", () => {
  it("returns whole clusters", () => {
    expect(firstGrapheme("\u{1F469}\u200d\u{1F4BB}x")).toBe("\u{1F469}\u200d\u{1F4BB}")
    expect(firstGrapheme("e\u0301x")).toBe("e\u0301")
    expect(firstGrapheme("")).toBe("")
  })
})

describe("copyText", () => {
  it("is the message text, with blocks separated by their line breaks", () => {
    const text = "Intro\n\nconst x = 1\nquote\n\n\nend"
    const doc = buildTextDocument(text, [e("pre", 7, 11), e("blockquote", 19, 5)])
    expect(doc.blocks.map((b) => b.kind)).toEqual(["paragraph", "codeBlock", "quote", "paragraph"])
    expect(copyText(doc)).toBe(text)
    expect(documentText(doc)).toBe(text)
  })

  it("keeps mentions as written and can append link targets", () => {
    const text = "@Ada read the docs at example.com"
    const doc = buildTextDocument(text, [
      e("mention", 0, 4, { userId: "1" as never }),
      e("textUrl", 14, 4, { url: "https://docs.example.com/a" }),
      e("url", 22, 11),
    ])
    expect(copyText(doc)).toBe(text)
    expect(copyText(doc, { linkTargets: true })).toBe("@Ada read the docs (https://docs.example.com/a) at example.com")
  })

  it("copies math and code as their source", () => {
    const text = "x^2 and code"
    const doc = buildTextDocument(text, [e("math", 0, 3), e("code", 8, 4)])
    expect(copyText(doc)).toBe(text)
  })
})
