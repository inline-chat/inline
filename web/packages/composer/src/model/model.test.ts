import type { ChatID, UserID } from "@inline/ids"
import { describe, expect, it } from "vitest"
import {
  applyBoldShortcut,
  collapsed,
  createDoc,
  deleteBackward,
  deleteForward,
  deleteRange,
  docLines,
  insertAtom,
  insertContent,
  insertLineBreak,
  insertText,
  isMarkActive,
  normalizeEntities,
  removeLink,
  setLink,
  setSelection,
  toggleMark,
  trimmedContent,
  type ComposerEntity,
  type DocState,
} from "./index"

const user = "42" as UserID
const at = (doc: DocState, offset: number) => setSelection(doc, collapsed(offset))
const sel = (doc: DocState, anchor: number, focus: number) => setSelection(doc, { anchor, focus })
const type = (doc: DocState, text: string) => [...text].reduce((d, ch) => insertText(d, ch), doc)
const ents = (doc: DocState) => doc.entities.map((e) => [e.type, e.offset, e.length])

describe("createDoc", () => {
  it("normalizes line endings, non-breaking spaces and controls, mapping entities", () => {
    const doc = createDoc({
      text: "a\r\nb\u00A0c\u0007d",
      entities: [{ type: "bold", offset: 3, length: 5 }],
    })
    expect(doc.text).toBe("a\nb cd")
    expect(ents(doc)).toEqual([["bold", 2, 4]])
  })

  it("keeps the zero-width non-joiner and joiner", () => {
    const text = "می\u200Cخواهم 👨\u200D👩\u200D👧"
    expect(createDoc({ text }).text).toBe(text)
  })

  it("puts the caret at the end", () => {
    expect(createDoc({ text: "hello" }).selection).toEqual({ anchor: 5, focus: 5 })
  })
})

describe("normalizeEntities", () => {
  it("clamps, drops empty, sorts and merges equal marks that touch", () => {
    const out = normalizeEntities("abcdefgh", [
      { type: "italic", offset: 5, length: 10 },
      { type: "bold", offset: 3, length: 2 },
      { type: "bold", offset: 0, length: 3 },
      { type: "underline", offset: 2, length: 0 },
      { type: "bold", offset: -4, length: 2 },
    ])
    expect(out.map((e) => [e.type, e.offset, e.length])).toEqual([
      ["bold", 0, 5],
      ["italic", 5, 3],
    ])
  })

  it("does not merge links with different URLs", () => {
    const out = normalizeEntities("abcd", [
      { type: "textUrl", offset: 0, length: 2, url: "https://a.example" },
      { type: "textUrl", offset: 2, length: 2, url: "https://b.example" },
    ])
    expect(out).toHaveLength(2)
  })

  it("grows ranges that split a surrogate pair", () => {
    const out = normalizeEntities("a😀b", [{ type: "bold", offset: 2, length: 1 }])
    expect(out[0]).toMatchObject({ offset: 1, length: 2 })
  })

  it("drops overlapping atoms and atoms across lines; marks cover whole atoms", () => {
    const out = normalizeEntities("@ab\n@cd", [
      { type: "mention", offset: 0, length: 3, userId: user },
      { type: "mention", offset: 1, length: 2, userId: user },
      { type: "mention", offset: 2, length: 3, userId: user },
      { type: "bold", offset: 1, length: 1 },
      { type: "url", offset: 1, length: 4 },
    ])
    expect(out.map((e) => [e.type, e.offset, e.length])).toEqual([
      ["bold", 0, 3],
      ["mention", 0, 3],
    ])
  })
})

describe("typing", () => {
  const bold = () => createDoc({ text: "abcd", entities: [{ type: "bold", offset: 1, length: 2 }] })

  it("grows a mark when typing strictly inside it", () => {
    const doc = insertText(at(bold(), 2), "X")
    expect(doc.text).toBe("abXcd")
    expect(ents(doc)).toEqual([["bold", 1, 3]])
  })

  it("does not grow a mark at its trailing or leading edge", () => {
    expect(ents(insertText(at(bold(), 3), "X"))).toEqual([["bold", 1, 2]])
    expect(ents(insertText(at(bold(), 1), "X"))).toEqual([["bold", 2, 2]])
  })

  it("grows at the trailing edge when the mark is pending, for every typed character", () => {
    let doc = toggleMark(at(createDoc({ text: "ab" }), 2), "bold")
    expect(isMarkActive(doc, "bold")).toBe(true)
    doc = type(doc, "cde")
    expect(doc.text).toBe("abcde")
    expect(ents(doc)).toEqual([["bold", 2, 3]])
    // A selection move ends the pending marks.
    doc = insertText(at(at(doc, 0), 5), "f")
    expect(ents(doc)).toEqual([["bold", 2, 3]])
  })

  it("continues a bold run when bold is pending at its trailing edge", () => {
    const doc = type(toggleMark(at(toggleMark(at(bold(), 3), "bold"), 3), "bold"), "Z")
    // toggled on then off: pending without bold, not inside: stays plain
    expect(ents(doc)).toEqual([["bold", 1, 2]])
    const on = type(toggleMark(at(bold(), 3), "bold"), "Z")
    expect(ents(on)).toEqual([["bold", 1, 3]])
  })

  it("splits a mark when typing inside it with the mark toggled off", () => {
    const doc = insertText(toggleMark(at(bold(), 2), "bold"), "X")
    expect(doc.text).toBe("abXcd")
    expect(ents(doc)).toEqual([
      ["bold", 1, 1],
      ["bold", 3, 1],
    ])
  })

  it("keeps the first character's marks when replacing a selection", () => {
    const doc = insertText(sel(bold(), 1, 3), "XYZ")
    expect(doc.text).toBe("aXYZd")
    expect(ents(doc)).toEqual([["bold", 1, 3]])
  })

  it("shifts entities after the edit and keeps the caret after the inserted text", () => {
    const doc = insertText(at(bold(), 0), "12")
    expect(ents(doc)).toEqual([["bold", 3, 2]])
    expect(doc.selection).toEqual(collapsed(2))
  })

  it("increments the revision on content changes only", () => {
    const doc = bold()
    expect(at(doc, 1).revision).toBe(doc.revision)
    expect(insertText(doc, "x").revision).toBe(doc.revision + 1)
  })

  it("drops a derived entity edited inside, shifts it otherwise", () => {
    const doc = createDoc({ text: "see a.com now", entities: [{ type: "url", offset: 4, length: 5 }] })
    expect(ents(insertText(at(doc, 6), "x"))).toEqual([])
    expect(ents(insertText(at(doc, 0), "x"))).toEqual([["url", 5, 5]])
    expect(ents(insertText(at(doc, 9), "x"))).toEqual([["url", 4, 5]])
  })

  it("inserts a line break inside a mark as part of it", () => {
    const doc = insertLineBreak(at(bold(), 2))
    expect(doc.text).toBe("ab\ncd")
    expect(ents(doc)).toEqual([["bold", 1, 3]])
  })
})

describe("deleting", () => {
  it("drops an emptied mark and merges equal marks brought together", () => {
    const doc = createDoc({
      text: "aXb",
      entities: [
        { type: "bold", offset: 0, length: 1 },
        { type: "bold", offset: 2, length: 1 },
      ],
    })
    expect(ents(deleteRange(doc, { from: 1, to: 2 }))).toEqual([["bold", 0, 2]])
    expect(ents(deleteRange(doc, { from: 0, to: 1 }))).toEqual([["bold", 1, 1]])
  })

  it("trims a mark partly covered by the deletion", () => {
    const doc = createDoc({ text: "abcdef", entities: [{ type: "italic", offset: 1, length: 4 }] })
    expect(ents(deleteRange(doc, { from: 3, to: 6 }))).toEqual([["italic", 1, 2]])
    expect(ents(deleteRange(doc, { from: 0, to: 2 }))).toEqual([["italic", 0, 3]])
  })

  it("deletes whole grapheme clusters backward and forward", () => {
    const family = "👨\u200D👩\u200D👧"
    const flag = "🇮🇷"
    const doc = createDoc({ text: `a${family}${flag}e\u0301` })
    let d = deleteBackward(doc)
    expect(d.text).toBe(`a${family}${flag}`)
    d = deleteBackward(d)
    expect(d.text).toBe(`a${family}`)
    d = deleteBackward(d)
    expect(d.text).toBe("a")
    const f = deleteForward(at(doc, 1))
    expect(f.text).toBe(`a${flag}e\u0301`)
  })

  it("deletes a line break as one unit at the start of a line", () => {
    const doc = at(createDoc({ text: "ab\ncd" }), 3)
    expect(deleteBackward(doc).text).toBe("abcd")
    expect(deleteForward(at(doc, 2)).text).toBe("abcd")
  })

  it("deletes words backward and forward", () => {
    const doc = createDoc({ text: "hello big world  " })
    expect(deleteBackward(doc, "word").text).toBe("hello big ")
    expect(deleteForward(at(doc, 5), "word").text).toBe("hello world  ")
    expect(deleteBackward(at(doc, 3), "word").text).toBe("lo big world  ")
  })

  it("deletes to the line start, then the line break", () => {
    const doc = at(createDoc({ text: "one\ntwo three" }), 11)
    const d = deleteBackward(doc, "line")
    expect(d.text).toBe("one\nee")
    expect(d.selection).toEqual(collapsed(4))
    expect(deleteBackward(d, "line").text).toBe("oneee")
    expect(deleteForward(at(doc, 5), "line").text).toBe("one\nt")
  })

  it("deletes the selection when it is not collapsed", () => {
    expect(deleteBackward(sel(createDoc({ text: "abcdef" }), 4, 1)).text).toBe("aef")
  })

  it("is a no-op at the edges", () => {
    const doc = at(createDoc({ text: "ab" }), 0)
    expect(deleteBackward(doc)).toBe(doc)
    const end = at(doc, 2)
    expect(deleteForward(end)).toBe(end)
  })
})

describe("atoms", () => {
  const withMention = () => insertAtom(createDoc({ text: "hi " }), { type: "mention", userId: user }, "@Mo")

  it("inserts an atom with a trailing space and the caret after it", () => {
    const doc = withMention()
    expect(doc.text).toBe("hi @Mo ")
    expect(doc.entities).toEqual([{ type: "mention", offset: 3, length: 3, userId: user }])
    expect(doc.selection).toEqual(collapsed(7))
  })

  it("deletes an atom as one unit with Backspace and Delete", () => {
    const doc = at(withMention(), 6)
    const back = deleteBackward(doc)
    expect(back.text).toBe("hi  ")
    expect(back.entities).toEqual([])
    expect(deleteForward(at(doc, 3)).text).toBe("hi  ")
  })

  it("grows a deletion that covers part of an atom to the whole atom", () => {
    const d = deleteRange(withMention(), { from: 1, to: 4 })
    expect(d.text).toBe("h ")
    expect(d.entities).toEqual([])
  })

  it("moves a caret out of an atom and types after it", () => {
    const doc = withMention()
    expect(at(doc, 4).selection).toEqual(collapsed(3))
    expect(at(doc, 5).selection).toEqual(collapsed(6))
    const typed = insertText(doc, "x", { from: 5, to: 5 })
    expect(typed.text).toBe("hi @Mox ")
    expect(typed.entities).toEqual([{ type: "mention", offset: 3, length: 3, userId: user }])
  })

  it("grows a range selection to whole atoms", () => {
    expect(sel(withMention(), 1, 4).selection).toEqual({ anchor: 1, focus: 6 })
    expect(sel(withMention(), 5, 0).selection).toEqual({ anchor: 6, focus: 0 })
  })

  it("replaces line breaks in labels and inserts groups and threads", () => {
    const doc = insertAtom(createDoc(), { type: "groupMention", groupId: "7" }, "@a\nb", { trailing: "" })
    expect(doc.text).toBe("@a b")
    const t = insertAtom(createDoc(), { type: "thread", chatId: "9" as ChatID }, "Plans")
    expect(t.entities[0]).toMatchObject({ type: "thread", chatId: "9", offset: 0, length: 5 })
  })

  it("does not grow a mark over an atom inserted at its edge", () => {
    const doc = createDoc({ text: "ab", entities: [{ type: "bold", offset: 0, length: 2 }] })
    const next = insertAtom(doc, { type: "mention", userId: user }, "@x", { trailing: "" })
    expect(ents(next)).toEqual([
      ["bold", 0, 2],
      ["mention", 2, 2],
    ])
  })
})

describe("marks", () => {
  it("adds a mark over a range, removes it when the range is fully marked", () => {
    let doc = sel(createDoc({ text: "hello world" }), 0, 5)
    doc = toggleMark(doc, "bold")
    expect(ents(doc)).toEqual([["bold", 0, 5]])
    expect(isMarkActive(doc, "bold")).toBe(true)
    doc = toggleMark(sel(doc, 2, 8), "bold")
    expect(ents(doc)).toEqual([["bold", 0, 8]])
    doc = toggleMark(sel(doc, 2, 4), "bold")
    expect(ents(doc)).toEqual([
      ["bold", 0, 2],
      ["bold", 4, 4],
    ])
  })

  it("ignores line breaks when deciding whether a range is marked", () => {
    const doc = createDoc({
      text: "ab\ncd",
      entities: [
        { type: "italic", offset: 0, length: 2 },
        { type: "italic", offset: 3, length: 2 },
      ],
    })
    expect(isMarkActive(sel(doc, 0, 5), "italic")).toBe(true)
    expect(ents(toggleMark(sel(doc, 0, 5), "italic"))).toEqual([])
  })

  it("sets, changes and removes links", () => {
    let doc = setLink(sel(createDoc({ text: "go here now" }), 3, 7), "https://a.example")
    expect(doc.entities).toEqual([{ type: "textUrl", offset: 3, length: 4, url: "https://a.example" }])
    doc = setLink(at(doc, 5), "https://b.example")
    expect(doc.entities[0]?.url).toBe("https://b.example")
    expect(removeLink(at(doc, 4)).entities).toEqual([])
    const inserted = setLink(at(createDoc({ text: "x " }), 2), "https://c.example")
    expect(inserted.text).toBe("x https://c.example")
    expect(ents(inserted)).toEqual([["textUrl", 2, 17]])
  })
})

describe("paste-like insertion", () => {
  it("inserts content with its own entities", () => {
    const doc = insertContent(at(createDoc({ text: "ab" }), 1), {
      text: "XY",
      entities: [{ type: "code", offset: 1, length: 1 }],
    })
    expect(doc.text).toBe("aXYb")
    expect(ents(doc)).toEqual([["code", 2, 1]])
  })
})

describe("trimmedContent", () => {
  it("trims whitespace and shifts entities", () => {
    const doc = createDoc({
      text: "\n  hi @Mo  \n",
      entities: [
        { type: "bold", offset: 0, length: 5 },
        { type: "mention", offset: 6, length: 3, userId: user },
      ],
    })
    const out = trimmedContent(doc)
    expect(out.text).toBe("hi @Mo")
    expect(out.entities.map((e) => [e.type, e.offset, e.length])).toEqual([
      ["bold", 0, 2],
      ["mention", 3, 3],
    ])
  })
})

describe("bold shortcut", () => {
  it("turns **text** into bold when the closing marker is typed", () => {
    let doc = type(createDoc({ text: "say " }), "**hi there*")
    expect(applyBoldShortcut(doc)).toBe(doc)
    doc = insertText(doc, "*")
    const out = applyBoldShortcut(doc)
    expect(out.text).toBe("say hi there")
    expect(ents(out)).toEqual([["bold", 4, 8]])
    expect(out.selection).toEqual(collapsed(12))
    expect(out.revision).toBeGreaterThan(doc.revision)
  })

  it("leaves whitespace-edged content and other lines alone", () => {
    const a = createDoc({ text: "2 ** 3 **" })
    expect(applyBoldShortcut(a)).toBe(a)
    const b = createDoc({ text: "**a\nb**" })
    expect(applyBoldShortcut(b)).toBe(b)
  })
})

describe("docLines", () => {
  it("splits lines and runs by marks and atoms", () => {
    const doc = createDoc({
      text: "ab @Mo\n\ncd",
      entities: [
        { type: "bold", offset: 1, length: 1 },
        { type: "mention", offset: 3, length: 3, userId: user },
        { type: "italic", offset: 8, length: 2 },
      ],
    })
    const lines = docLines(doc)
    expect(lines.map((l) => [l.start, l.text])).toEqual([
      [0, "ab @Mo"],
      [7, ""],
      [8, "cd"],
    ])
    expect(lines[0]!.runs.map((r) => (r.kind === "atom" ? `@${r.text}` : `${r.marks.map((m) => m.type)}:${r.text}`))).toEqual([
      ":a",
      "bold:b",
      ": ",
      "@@Mo",
    ])
    expect(lines[1]!.runs).toEqual([])
    expect(lines[0]!.key).toBe(docLines(createDoc(doc)).at(0)!.key)
  })
})

describe("entities survive many edits", () => {
  it("keeps a mention through edits around it", () => {
    let doc: DocState = insertAtom(createDoc({ text: "x" }), { type: "mention", userId: user }, "@Mo")
    doc = insertText(at(doc, 0), "abc ")
    doc = deleteBackward(at(doc, 2))
    const m = doc.entities.find((e: ComposerEntity) => e.type === "mention")!
    expect(doc.text.slice(m.offset, m.offset + m.length)).toBe("@Mo")
  })
})
