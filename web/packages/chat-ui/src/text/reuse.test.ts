import { describe, expect, it } from "vitest"
import type { EntityInput, ParagraphNode, TextDocument } from "./types"
import { buildTextDocument } from "./build"
import { changedBlockKeys, reuseUnchanged, updateTextDocument } from "./reuse"

const e = (type: EntityInput["type"], offset: number, length: number, extra: Partial<EntityInput> = {}): EntityInput =>
  ({ type, offset, length, ...extra }) as EntityInput

/** Streams `full` in chunks, as an agent edits its message in place. */
const stream = (full: string, chunk: number, entitiesAt: (text: string) => EntityInput[] = () => []): TextDocument[] => {
  const docs: TextDocument[] = []
  let doc: TextDocument | undefined
  for (let end = chunk; end < full.length + chunk; end += chunk) {
    const text = full.slice(0, Math.min(end, full.length))
    doc = updateTextDocument(doc, text, entitiesAt(text))
    docs.push(doc)
  }
  return docs
}

describe("stable keys under streaming appends", () => {
  it("keeps earlier blocks' keys and identities when text is appended", () => {
    const first = updateTextDocument(undefined, "Intro paragraph.\n\nSecond paragraph is gr")
    const second = updateTextDocument(first, "Intro paragraph.\n\nSecond paragraph is growing")
    expect(second.blocks.map((b) => b.key)).toEqual(first.blocks.map((b) => b.key))
    expect(second.blocks[0]).toBe(first.blocks[0])
    expect(second.blocks[1]).not.toBe(first.blocks[1])
    expect(changedBlockKeys(first, second)).toEqual(["p18"])
  })

  it("adds a new block without touching the earlier ones", () => {
    const first = updateTextDocument(undefined, "One.\n\nTwo.")
    const second = updateTextDocument(first, "One.\n\nTwo.\n\nThree")
    expect(second.blocks[0]).toBe(first.blocks[0])
    expect(second.blocks[1]).toBe(first.blocks[1])
    expect(changedBlockKeys(first, second)).toEqual(["p12"])
  })

  it("does not change the last paragraph while only its separator has arrived", () => {
    const first = updateTextDocument(undefined, "One.")
    const second = updateTextDocument(first, "One.\n")
    const third = updateTextDocument(second, "One.\n\n")
    expect(third.blocks[0]).toBe(first.blocks[0])
  })

  it("keeps earlier runs inside the growing paragraph", () => {
    const entities = [e("bold", 0, 4)]
    const first = updateTextDocument(undefined, "Bold then plain", entities)
    const second = updateTextDocument(first, "Bold then plain and more", entities)
    const before = (first.blocks[0] as ParagraphNode).children
    const after = (second.blocks[0] as ParagraphNode).children
    expect(after[0]).toBe(before[0])
    expect(after[1]).not.toBe(before[1])
    expect(after.map((n) => n.key)).toEqual(before.map((n) => n.key))
  })

  it("keeps identities across a whole streamed reply with code and quotes", () => {
    const full = "Plan:\n\nfirst step here\n\nconst a = 1\n\nquoted line\n\nlast words of the reply"
    const entitiesAt = (text: string): EntityInput[] => {
      const out: EntityInput[] = [e("bold", 0, 4)]
      const code = full.indexOf("const a = 1")
      if (text.length >= code + 11) out.push(e("pre", code, 11, { language: "ts" }))
      const quote = full.indexOf("quoted line")
      if (text.length >= quote + 11) out.push(e("blockquote", quote, 11))
      return out
    }
    const docs = stream(full, 3, entitiesAt)
    for (let i = 1; i < docs.length; i += 1) {
      const prev = docs[i - 1] as TextDocument
      const next = docs[i] as TextDocument
      const changed = changedBlockKeys(prev, next)
      // At most the last block of the previous document and whatever was added after it change,
      // except when an entity arrives and reshapes the block it covers.
      const lastPrev = prev.blocks[prev.blocks.length - 1]
      for (const block of next.blocks) {
        if (!changed.includes(block.key)) continue
        const isNewOrLast = !prev.blocks.some((b) => b.key === block.key) || block.key === lastPrev?.key
        expect(isNewOrLast).toBe(true)
      }
    }
    const final = docs[docs.length - 1] as TextDocument
    expect(final.blocks.map((b) => b.kind)).toEqual(["paragraph", "paragraph", "codeBlock", "quote", "paragraph"])
  })

  it("returns the previous document for the same input", () => {
    const entities = [e("italic", 0, 2)]
    const first = updateTextDocument(undefined, "hi there", entities)
    expect(updateTextDocument(first, "hi there", entities)).toBe(first)
    // A new but equal entities array rebuilds and still reuses everything.
    expect(updateTextDocument(first, "hi there", [e("italic", 0, 2)])).toBe(first)
  })

  it("rebuilds what an edit in the middle changes and keeps the rest", () => {
    const first = updateTextDocument(undefined, "aaa\n\nbbb\n\nccc")
    const second = updateTextDocument(first, "aaa\n\nbXb\n\nccc")
    expect(second.blocks[0]).toBe(first.blocks[0])
    expect(second.blocks[1]).not.toBe(first.blocks[1])
    expect(second.blocks[2]).toBe(first.blocks[2])
  })
})

describe("reuseUnchanged", () => {
  it("returns prev when equal and next's new parts otherwise", () => {
    const a = buildTextDocument("x\n\ny")
    const b = buildTextDocument("x\n\ny")
    expect(a).not.toBe(b)
    expect(reuseUnchanged(a, b)).toBe(a)
  })

  it("matches keyed arrays by key, not by index", () => {
    const prev = [
      { key: "a", v: 1 },
      { key: "b", v: 2 },
    ]
    const next = [
      { key: "z", v: 0 },
      { key: "a", v: 1 },
      { key: "b", v: 2 },
    ]
    const out = reuseUnchanged(prev, next)
    expect(out[1]).toBe(prev[0])
    expect(out[2]).toBe(prev[1])
    expect(out[0]).toBe(next[0])
  })
})
