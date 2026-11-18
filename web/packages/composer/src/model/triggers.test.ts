import type { UserID } from "@inline/ids"
import { describe, expect, it } from "vitest"
import {
  collapsed,
  createDoc,
  detectCommand,
  detectEmoji,
  detectMention,
  detectTrigger,
  insertAtom,
  setSelection,
} from "./index"

const caretAt = (text: string, caret = text.length) => setSelection(createDoc({ text }), collapsed(caret))

describe("mention trigger", () => {
  it("detects @ at the start or after whitespace", () => {
    expect(detectMention("@mo", 3)).toEqual({ kind: "mention", query: "mo", range: { from: 0, to: 3 } })
    expect(detectMention("hi @", 4)).toEqual({ kind: "mention", query: "", range: { from: 3, to: 4 } })
    expect(detectMention("a\n@x", 4)?.range).toEqual({ from: 2, to: 4 })
  })

  it("ignores @ inside a word or after whitespace was typed", () => {
    expect(detectMention("mail@host", 9)).toBeNull()
    expect(detectMention("@mo ", 4)).toBeNull()
  })

  it("replaces to the end of the word past the caret", () => {
    expect(detectMention("@mohammad hi", 3)).toEqual({ kind: "mention", query: "mo", range: { from: 0, to: 9 } })
  })

  it("does not trigger on an existing mention chip", () => {
    const doc = insertAtom(createDoc(), { type: "mention", userId: "1" as UserID }, "@Mo", { trailing: "" })
    expect(detectTrigger(doc)).toBeNull()
  })
})

describe("emoji trigger", () => {
  it("needs at least one query character", () => {
    expect(detectEmoji(":", 1)).toBeNull()
    expect(detectEmoji("hi :s", 5)).toEqual({ kind: "emoji", query: "s", range: { from: 3, to: 5 } })
    expect(detectEmoji(":+1", 3)?.query).toBe("+1")
  })

  it("does not trigger after a letter or digit", () => {
    expect(detectEmoji("10:30", 5)).toBeNull()
    expect(detectEmoji("http://x", 8)).toBeNull()
    expect(detectEmoji("سلام:x", 6)).toBeNull()
  })

  it("stops at characters that cannot be in a query", () => {
    expect(detectEmoji(":a b", 4)).toBeNull()
    expect(detectEmoji(":a.b", 4)).toBeNull()
  })
})

describe("command trigger", () => {
  it("detects / when it starts the message and nothing follows", () => {
    expect(detectCommand("/", 1)).toEqual({ kind: "command", query: "", range: { from: 0, to: 1 } })
    expect(detectCommand("  /ren", 6)?.query).toBe("ren")
    expect(detectCommand("/rename  ", 7)?.range).toEqual({ from: 0, to: 7 })
  })

  it("does not trigger elsewhere", () => {
    expect(detectCommand("hi /x", 5)).toBeNull()
    expect(detectCommand("/x y", 2)).toBeNull()
    expect(detectCommand("a/b", 3)).toBeNull()
  })
})

describe("detectTrigger", () => {
  it("needs a collapsed caret and prefers the command", () => {
    expect(detectTrigger(caretAt("/x"))?.kind).toBe("command")
    expect(detectTrigger(caretAt("hi @x"))?.kind).toBe("mention")
    expect(detectTrigger(caretAt("hi :x"))?.kind).toBe("emoji")
    expect(detectTrigger(setSelection(createDoc({ text: "@x" }), { anchor: 0, focus: 2 }))).toBeNull()
  })
})
