import { describe, expect, it } from "vitest"
import { isPastePlainKey, keyCommand, type KeyContext, type KeyInput } from "./keys"

const input = (key: string, mods: Partial<KeyInput> = {}): KeyInput => ({
  key,
  shiftKey: false,
  altKey: false,
  ctrlKey: false,
  metaKey: false,
  ...mods,
})
const mac: KeyContext = { platform: "mac", sendKey: "enter", autocomplete: false, empty: false }
const win: KeyContext = { ...mac, platform: "other" }

describe("keyCommand", () => {
  const table: [string, KeyInput, KeyContext, unknown][] = [
    ["Enter sends", input("Enter"), mac, { kind: "send" }],
    ["Enter is a new line with Mod+Enter to send", input("Enter"), { ...mac, sendKey: "modEnter" }, { kind: "newline" }],
    ["Shift+Enter is always a new line", input("Enter", { shiftKey: true }), mac, { kind: "newline" }],
    ["Alt+Enter is a new line", input("Enter", { altKey: true }), mac, { kind: "newline" }],
    ["Cmd+Enter always sends on Mac", input("Enter", { metaKey: true }), { ...mac, sendKey: "modEnter" }, { kind: "send" }],
    ["Ctrl+Enter always sends elsewhere", input("Enter", { ctrlKey: true }), { ...win, sendKey: "modEnter" }, { kind: "send" }],
    ["Ctrl+Enter on Mac is left alone", input("Enter", { ctrlKey: true }), mac, null],
    ["composition is left alone", input("Enter", { isComposing: true }), mac, null],
    ["Up in an empty composer edits", input("ArrowUp"), { ...mac, empty: true }, { kind: "editLast" }],
    ["Up with text moves the caret", input("ArrowUp"), mac, null],
    ["Shift+Up in an empty composer selects", input("ArrowUp", { shiftKey: true }), { ...mac, empty: true }, null],
    ["Escape", input("Escape"), mac, { kind: "escape" }],
    ["Cmd+B", input("b", { metaKey: true }), mac, { kind: "toggleMark", mark: "bold" }],
    ["Ctrl+B elsewhere", input("b", { ctrlKey: true }), win, { kind: "toggleMark", mark: "bold" }],
    ["Ctrl+B on Mac is the caret move", input("b", { ctrlKey: true }), mac, null],
    ["Cmd+I", input("i", { metaKey: true }), mac, { kind: "toggleMark", mark: "italic" }],
    ["Cmd+U", input("u", { metaKey: true }), mac, { kind: "toggleMark", mark: "underline" }],
    ["Cmd+Shift+C", input("C", { metaKey: true, shiftKey: true }), mac, { kind: "toggleMark", mark: "code" }],
    ["Cmd+C is copy", input("c", { metaKey: true }), mac, null],
    ["Cmd+Shift+X", input("x", { metaKey: true, shiftKey: true }), mac, { kind: "toggleMark", mark: "strikethrough" }],
    ["Cmd+Z", input("z", { metaKey: true }), mac, { kind: "undo" }],
    ["Cmd+Shift+Z", input("Z", { metaKey: true, shiftKey: true }), mac, { kind: "redo" }],
    ["Ctrl+Y elsewhere", input("y", { ctrlKey: true }), win, { kind: "redo" }],
    ["Cmd+Y on Mac is not redo", input("y", { metaKey: true }), mac, null],
    ["Cmd+K", input("k", { metaKey: true }), mac, { kind: "link" }],
    ["autocomplete Down", input("ArrowDown"), { ...mac, autocomplete: true }, { kind: "autocomplete", key: "next" }],
    ["autocomplete Up", input("ArrowUp"), { ...mac, autocomplete: true, empty: true }, { kind: "autocomplete", key: "previous" }],
    ["autocomplete Tab", input("Tab"), { ...mac, autocomplete: true }, { kind: "autocomplete", key: "accept" }],
    ["autocomplete Enter", input("Enter"), { ...mac, autocomplete: true }, { kind: "autocomplete", key: "accept" }],
    ["autocomplete Shift+Enter is a new line", input("Enter", { shiftKey: true }), { ...mac, autocomplete: true }, { kind: "newline" }],
    ["autocomplete Escape", input("Escape"), { ...mac, autocomplete: true }, { kind: "autocomplete", key: "dismiss" }],
    ["plain letters", input("a"), mac, null],
  ]
  for (const [name, key, context, expected] of table) {
    it(name, () => expect(keyCommand(key, context)).toEqual(expected))
  }

  it("recognizes paste and match style", () => {
    expect(isPastePlainKey(input("V", { metaKey: true, shiftKey: true }), "mac")).toBe(true)
    expect(isPastePlainKey(input("v", { ctrlKey: true, shiftKey: true }), "other")).toBe(true)
    expect(isPastePlainKey(input("v", { metaKey: true }), "mac")).toBe(false)
  })
})
