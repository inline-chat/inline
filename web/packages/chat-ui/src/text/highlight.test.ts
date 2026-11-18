import { describe, expect, it } from "vitest"
import { buildTextDocument } from "./build"
import { applyHighlights, highlightTextDocument, normalizeHighlightRanges } from "./highlight"
import type { BlockNode, EntityInput, InlineNode, TextDocument } from "./types"

const e = (type: EntityInput["type"], offset: number, length: number, extra: Partial<EntityInput> = {}): EntityInput =>
  ({ type, offset, length, ...extra }) as EntityInput

/** Runs of a paragraph-like block as `[text, marks]`, flattening containers as `kind(...)`. */
const runs = (block: BlockNode | undefined): unknown[] => {
  const flatten = (node: InlineNode): unknown =>
    node.kind === "text"
      ? [node.text, node.marks.join("+")]
      : node.kind === "math"
        ? ["math", node.source]
        : [node.kind, node.children.map((child) => [child.text, child.marks.join("+")])]
  if (block?.kind === "paragraph") return block.children.map(flatten)
  return []
}

describe("find highlights in the render model", () => {
  it("splits runs at range edges across entity edges", () => {
    const doc = buildTextDocument("Hello bold world", [e("bold", 6, 4)])
    const out = applyHighlights(doc, [[3, 8]])
    expect(runs(out.blocks[0])).toEqual([
      ["Hel", ""],
      ["lo ", "find"],
      ["bo", "find+bold"],
      ["ld", "bold"],
      [" world", ""],
    ])
    // Keys stay unique and positional.
    const first = out.blocks[0]
    expect(first?.kind === "paragraph" && first.children.map((child) => child.key)).toEqual(["t0", "t3", "t6", "t8", "t10"])
  })

  it("highlights inside a link and a mention, keeping the container", () => {
    const text = "see https://example.com and @ada"
    const doc = buildTextDocument(text, [e("url", 4, 19), e("mention", 28, 4, { userId: "7" as never })])
    const out = applyHighlights(doc, [{ start: 12, end: 19 }, { start: 29, end: 32 }])
    expect(runs(out.blocks[0])).toEqual([
      ["see ", ""],
      [
        "link",
        [
          ["https://", ""],
          ["example", "find"],
          [".com", ""],
        ],
      ],
      [" and ", ""],
      [
        "mention",
        [
          ["@", ""],
          ["ada", "find"],
        ],
      ],
    ])
    const link = out.blocks[0]?.kind === "paragraph" ? out.blocks[0].children[1] : undefined
    expect(link?.kind === "link" && link.link.kind === "web" && link.link.href).toBe("https://example.com/")
  })

  it("spans lines inside a paragraph and across two paragraphs", () => {
    expect(runs(applyHighlights(buildTextDocument("a\nb c"), [[0, 3]]).blocks[0])).toEqual([
      ["a\nb", "find"],
      [" c", ""],
    ])
    const doc = buildTextDocument("One two\n\nThree four\n\nFive")
    const out = applyHighlights(doc, [[4, 14]])
    expect(runs(out.blocks[0])).toEqual([
      ["One ", ""],
      ["two", "find"],
    ])
    expect(runs(out.blocks[1])).toEqual([
      ["Three", "find"],
      [" four", ""],
    ])
    expect(out.blocks[2]).toBe(doc.blocks[2])
  })

  it("highlights inside code blocks, but not math", () => {
    const text = "Run:\nnpm test\n\nx^2 here"
    const doc = buildTextDocument(text, [e("pre", 5, 8), e("math", 15, 3)])
    const out = applyHighlights(doc, [
      [9, 13],
      [15, 18],
    ])
    const code = out.blocks.find((block) => block.kind === "codeBlock")
    expect(code?.kind === "codeBlock" && code.find).toEqual([{ start: 4, end: 8 }])
    const math = out.blocks.at(-1)
    expect(runs(math)).toEqual([
      ["math", "x^2"],
      [" here", ""],
    ])
  })

  it("widens to grapheme clusters and merges overlaps", () => {
    const text = "éx 👍🏽!"
    expect(normalizeHighlightRanges(text, [[0, 1]])).toEqual([{ start: 0, end: 2 }])
    // The skin tone modifier joins the thumbs up: widen to both.
    expect(normalizeHighlightRanges(text, [[4, 6]])).toEqual([{ start: 4, end: 8 }])
    expect(normalizeHighlightRanges(text, [[0, 2], [1, 3], [3, 4]])).toEqual([{ start: 0, end: 4 }])
  })

  it("degrades malformed and out-of-range input to no highlight", () => {
    const doc = buildTextDocument("plain 😀 text")
    const bad: unknown[] = [
      [-1, 3],
      [3, 3],
      [5, 2],
      [0, 999],
      [Number.NaN, 2],
      [0.5, 2],
      ["0", "2"],
      { start: 7, end: 8 }, // splits the emoji's surrogate pair
      null,
      "0-2",
      [],
    ]
    expect(applyHighlights(doc, bad as never)).toBe(doc)
    expect(applyHighlights(doc, undefined)).toBe(doc)
    expect(applyHighlights(doc, "nope" as never)).toBe(doc)
    expect(highlightTextDocument(doc, bad as never)).toBe(doc)
  })

  it("keeps identity when ranges do not change, and touches only affected paragraphs when they do", () => {
    const doc: TextDocument = buildTextDocument("First para\n\nSecond para\n\nThird para")
    const a = highlightTextDocument(doc, [[0, 5]])
    expect(highlightTextDocument(doc, [[0, 5]])).toBe(a)
    expect(highlightTextDocument(doc, [{ start: 0, end: 5 }])).toBe(a)
    expect(a.blocks[1]).toBe(doc.blocks[1])
    expect(a.blocks[2]).toBe(doc.blocks[2])

    // Add a range in the third paragraph: the first keeps its highlighted object.
    const b = highlightTextDocument(doc, [
      [0, 5],
      [25, 30],
    ])
    expect(b.blocks[0]).toBe(a.blocks[0])
    expect(b.blocks[1]).toBe(doc.blocks[1])
    expect(b.blocks[2]).not.toBe(doc.blocks[2])

    // Move the match to the second paragraph: the first goes back to the original.
    const c = highlightTextDocument(doc, [[12, 18]])
    expect(c.blocks[0]).toBe(doc.blocks[0])
    expect(c.blocks[1]).not.toBe(doc.blocks[1])
    expect(c.blocks[2]).toBe(doc.blocks[2])
  })
})
