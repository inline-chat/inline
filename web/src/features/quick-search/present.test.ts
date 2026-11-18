import { describe, expect, it } from "vitest"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { parseCombo } from "@inline/view"
import type { QuickSearchItem } from "@inline/view/quick-search"
import {
  formatHitDate,
  highlightSegments,
  itemLabel,
  kindLabel,
  paletteKeyAction,
  pointerIntent,
  pointerMoved,
  revealDelta,
  sameItem,
  shortcutKeys, messageTitleMaxWidth } from "./present"

const chat = (extra: Partial<Extract<QuickSearchItem, { kind: "chat" }>> = {}): QuickSearchItem => ({
  kind: "chat",
  id: "chat:1",
  section: "chats",
  title: "Design review",
  titleRanges: [[0, 3]],
  chatId: "1" as ChatID,
  unread: false,
  ...extra,
})

const text = (segments: readonly { text: string; highlighted: boolean }[]) =>
  segments.map((segment) => (segment.highlighted ? `[${segment.text}]` : segment.text)).join("")

describe("highlightSegments", () => {
  it("splits at ranges, merging overlaps and sorting", () => {
    expect(text(highlightSegments("Product Meeting", [[8, 9], [0, 1]]))).toBe("[P]roduct [M]eeting")
    expect(text(highlightSegments("abcdef", [[3, 5], [1, 4]]))).toBe("a[bcde]f")
    expect(text(highlightSegments("abcdef", [[0, 2], [2, 4]]))).toBe("[abcd]ef")
  })

  it("returns one plain run without ranges and nothing for empty text", () => {
    expect(highlightSegments("Hello", [])).toEqual([{ text: "Hello", highlighted: false }])
    expect(highlightSegments("Hello", undefined)).toEqual([{ text: "Hello", highlighted: false }])
    expect(highlightSegments("", [[0, 1]])).toEqual([])
  })

  it("clamps out-of-range and drops empty or malformed ranges", () => {
    expect(text(highlightSegments("abc", [[-5, 1], [2, 99]]))).toBe("[a]b[c]")
    expect(text(highlightSegments("abc", [[2, 2], [3, 1], [Number.NaN, 2]] as never))).toBe("abc")
    expect(text(highlightSegments("abc", ["x" as never]))).toBe("abc")
  })

  it("never splits a surrogate pair", () => {
    // "a😀b": the emoji is two UTF-16 units at 1..3.
    expect(text(highlightSegments("a😀b", [[2, 3]]))).toBe("a[😀]b")
    expect(text(highlightSegments("a😀b", [[1, 2]]))).toBe("a[😀]b")
  })

  it("keeps right-to-left text in logical order", () => {
    // Persian "سلام دنیا": highlight the second word by its UTF-16 offsets.
    const value = "سلام دنیا"
    expect(text(highlightSegments(value, [[5, 9]]))).toBe("سلام [دنیا]")
  })
})

describe("labels", () => {
  it("follows the Mac's trailing labels", () => {
    expect(kindLabel(chat())).toBe("Thread")
    expect(kindLabel(chat({ peerUserId: "2" as UserID }))).toBe("User")
    expect(kindLabel({ kind: "user", id: "user:2", section: "chats", title: "Ada", titleRanges: [], userId: "2" as UserID, remote: true, user: { kind: "user", id: "2" as UserID, bot: true } })).toBe("Bot")
    expect(kindLabel({ kind: "space", id: "space:1", section: "spaces", title: "Platform", titleRanges: [], spaceId: "1" as never })).toBe("Space")
    expect(kindLabel({ kind: "command", id: "command:x", section: "commands", title: "Back", titleRanges: [], commandId: "x", category: "navigation" })).toBe("Navigation")
  })

  it("names a row by title, secondary text and kind", () => {
    expect(itemLabel(chat({ subtitle: "Platform" }))).toBe("Design review, Platform, Thread")
    const message: QuickSearchItem = {
      kind: "message",
      id: "message:1:2",
      section: "messages",
      title: "Design review",
      titleRanges: [],
      chatId: "1" as ChatID,
      messageId: "2" as MessageID,
      date: 1,
      snippet: "the deploy is done",
      snippetRanges: [],
      remote: false,
    }
    expect(itemLabel(message, "3:04 PM")).toBe("Design review, the deploy is done, Message, 3:04 PM")
  })
})

describe("shortcutKeys", () => {
  it("splits the formatted combo into keys per platform", () => {
    expect(shortcutKeys(parseCombo("Mod+K", "mac"), "mac")).toEqual(["⌘", "K"])
    expect(shortcutKeys(parseCombo("Mod+Shift+E", "mac"), "mac")).toEqual(["⇧", "⌘", "E"])
    expect(shortcutKeys(parseCombo("Alt+ArrowUp", "mac"), "mac")).toEqual(["⌥", "↑"])
    expect(shortcutKeys(parseCombo("Mod+K", "windows"), "windows")).toEqual(["Ctrl", "K"])
    expect(shortcutKeys(parseCombo("Alt+ArrowLeft", "linux"), "linux")).toEqual(["Alt", "Left"])
    expect(shortcutKeys(parseCombo("Mod+,", "windows"), "windows")).toEqual(["Ctrl", ","])
  })
})

describe("formatHitDate", () => {
  const now = new Date(2026, 10, 17, 15, 0).getTime()
  it("shows the time today, the day this year, the full date before", () => {
    const today = new Date(2026, 10, 17, 9, 30).getTime() / 1000
    const thisYear = new Date(2026, 2, 4, 9, 30).getTime() / 1000
    const lastYear = new Date(2024, 2, 4, 9, 30).getTime() / 1000
    expect(formatHitDate(today, now)).toMatch(/9.30/)
    expect(formatHitDate(thisYear, now)).not.toMatch(/2026/)
    expect(formatHitDate(lastYear, now)).toMatch(/2024/)
    expect(formatHitDate(0, now)).toBe("")
    // Cached: the same string object comes back.
    expect(formatHitDate(today, now)).toBe(formatHitDate(today, now))
  })
})

describe("sameItem", () => {
  it("is true for the same object or the same content", () => {
    const a = chat()
    expect(sameItem(a, a)).toBe(true)
    expect(sameItem(a, chat())).toBe(true)
  })

  it("is false when anything shown differs", () => {
    expect(sameItem(chat(), chat({ titleRanges: [[0, 4]] }))).toBe(false)
    expect(sameItem(chat(), chat({ title: "Design" }))).toBe(false)
    expect(sameItem(chat(), chat({ unread: true }))).toBe(false)
    expect(sameItem(chat(), chat({ section: "suggestions" }))).toBe(false)
    expect(sameItem(chat(), chat({ emoji: "🚀" }))).toBe(false)
  })
})

describe("paletteKeyAction", () => {
  const key = (k: string, extra: Record<string, unknown> = {}) => ({ key: k, ...extra })

  it("maps arrows, Tab and Enter to the model", () => {
    expect(paletteKeyAction(key("ArrowDown"), "mac", false)).toEqual({ kind: "next" })
    expect(paletteKeyAction(key("ArrowUp"), "mac", false)).toEqual({ kind: "previous" })
    expect(paletteKeyAction(key("ArrowDown", { metaKey: true }), "mac", false)).toEqual({ kind: "last" })
    expect(paletteKeyAction(key("ArrowUp", { ctrlKey: true }), "windows", false)).toEqual({ kind: "first" })
    expect(paletteKeyAction(key("Tab"), "mac", false)).toEqual({ kind: "nextSection" })
    expect(paletteKeyAction(key("Tab", { shiftKey: true }), "mac", false)).toEqual({ kind: "previousSection" })
    expect(paletteKeyAction(key("Enter"), "mac", false)).toEqual({ kind: "activate", intent: "here" })
    expect(paletteKeyAction(key("Enter", { metaKey: true }), "mac", false)).toEqual({ kind: "activate", intent: "otherPane" })
    expect(paletteKeyAction(key("Enter", { ctrlKey: true }), "windows", false)).toEqual({ kind: "activate", intent: "otherPane" })
    expect(paletteKeyAction(key("k", { metaKey: true }), "mac", false)).toEqual({ kind: "close" })
    expect(paletteKeyAction(key("n", { ctrlKey: true }), "mac", false)).toEqual({ kind: "next" })
  })

  it("leaves Home and End to the caret while there is text", () => {
    expect(paletteKeyAction(key("Home"), "mac", false)).toBeUndefined()
    expect(paletteKeyAction(key("End"), "mac", false)).toBeUndefined()
    expect(paletteKeyAction(key("Home"), "mac", true)).toEqual({ kind: "first" })
    expect(paletteKeyAction(key("End"), "mac", true)).toEqual({ kind: "last" })
  })

  it("fires nothing while an input method composes", () => {
    expect(paletteKeyAction(key("Enter", { isComposing: true }), "mac", false)).toBeUndefined()
    expect(paletteKeyAction(key("ArrowDown", { isComposing: true }), "mac", false)).toBeUndefined()
    expect(paletteKeyAction(key("Process"), "mac", false)).toBeUndefined()
    expect(paletteKeyAction(key("Enter", { keyCode: 229 }), "mac", false)).toBeUndefined()
  })

  it("ignores typing and unrelated modifiers", () => {
    expect(paletteKeyAction(key("a"), "mac", false)).toBeUndefined()
    expect(paletteKeyAction(key("Enter", { shiftKey: true }), "mac", false)).toBeUndefined()
    expect(paletteKeyAction(key("ArrowDown", { altKey: true }), "mac", false)).toBeUndefined()
    expect(paletteKeyAction(key("Escape"), "mac", false)).toBeUndefined()
    // Ctrl+N is not a list key off the Mac.
    expect(paletteKeyAction(key("n", { ctrlKey: true }), "windows", false)).toBeUndefined()
  })
})

describe("pointer helpers", () => {
  it("maps clicks to intents", () => {
    expect(pointerIntent({ button: 0 }, "mac")).toBe("here")
    expect(pointerIntent({ button: 0, metaKey: true }, "mac")).toBe("otherPane")
    expect(pointerIntent({ button: 0, ctrlKey: true }, "linux")).toBe("otherPane")
    expect(pointerIntent({ button: 1 }, "mac")).toBe("newTab")
    expect(pointerIntent({ button: 2 }, "mac")).toBeUndefined()
  })

  it("tells real movement from a still pointer", () => {
    expect(pointerMoved(undefined, { x: 1, y: 1 })).toBe(true)
    expect(pointerMoved({ x: 1, y: 1 }, { x: 1, y: 1 })).toBe(false)
    expect(pointerMoved({ x: 1, y: 1 }, { x: 1, y: 2 })).toBe(true)
  })

  it("scrolls the least to reveal a row", () => {
    const view = { top: 100, bottom: 300 }
    expect(revealDelta(view, { top: 150, bottom: 184 })).toBe(0)
    expect(revealDelta(view, { top: 80, bottom: 114 }, 8)).toBe(-28)
    expect(revealDelta(view, { top: 290, bottom: 324 }, 8)).toBe(32)
    // Taller than the view: align the top.
    expect(revealDelta(view, { top: 120, bottom: 500 })).toBe(20)
  })
})

describe("messageTitleMaxWidth", () => {
  const em = 13
  it("gives the title 40% of the column in the palette's usual widths", () => {
    // 510 px palette (750 and 1280 px windows): the text column is about 380 px.
    expect(messageTitleMaxWidth(380, em)).toBeCloseTo(152)
    // 480 px window: the palette is 448 px, the column about 320 px.
    expect(messageTitleMaxWidth(320, em)).toBeCloseTo(128)
  })
  it("never goes under 7em while the column has room, nor over 16em", () => {
    expect(messageTitleMaxWidth(200, em)).toBe(91)
    expect(messageTitleMaxWidth(1000, em)).toBe(208)
  })
  it("keeps half a very narrow column for the snippet", () => {
    expect(messageTitleMaxWidth(120, em)).toBe(60)
    expect(messageTitleMaxWidth(-5, em)).toBe(0)
  })
})
