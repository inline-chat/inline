import { describe, expect, it } from "vitest"
import type { KeyEventLike } from "@inline/view"
import { chatSelectionText } from "./selection"
import { ariaShortcut, findKeyAction, findListMetrics, listHeight, listWindow, revealRow, shortcutHint, snippetRuns } from "./present"
import { findShortcuts } from "./commands"

const key = (k: string, mods: Partial<KeyEventLike> = {}): KeyEventLike => ({
  key: k,
  ctrlKey: false,
  metaKey: false,
  altKey: false,
  shiftKey: false,
  ...mods,
})

const text = (runs: readonly { text: string; highlighted: boolean }[]) =>
  runs.map((run) => (run.highlighted ? `[${run.text}]` : run.text)).join("")

describe("findKeyAction", () => {
  it("maps Enter, Shift+Enter and Escape", () => {
    expect(findKeyAction(key("Enter"), { showsResults: true })).toBe("submit")
    expect(findKeyAction(key("Enter", { shiftKey: true }), { showsResults: false })).toBe("previous")
    expect(findKeyAction(key("Escape"), { showsResults: false })).toBe("close")
    expect(findKeyAction(key("Enter", { metaKey: true }), { showsResults: false })).toBeUndefined()
  })

  it("moves through the list over the previews, and steps over the chat (up is older)", () => {
    expect(findKeyAction(key("ArrowUp"), { showsResults: true })).toBe("moveNewer")
    expect(findKeyAction(key("ArrowDown"), { showsResults: true })).toBe("moveOlder")
    expect(findKeyAction(key("ArrowUp"), { showsResults: false })).toBe("next")
    expect(findKeyAction(key("ArrowDown"), { showsResults: false })).toBe("previous")
    expect(findKeyAction(key("ArrowUp", { shiftKey: true }), { showsResults: true })).toBeUndefined()
    expect(findKeyAction(key("ArrowLeft"), { showsResults: true })).toBeUndefined()
  })

  it("ignores keys while composing", () => {
    expect(findKeyAction(key("Enter", { isComposing: true }), { showsResults: true })).toBeUndefined()
    expect(findKeyAction(key("Enter", { keyCode: 229 }), { showsResults: true })).toBeUndefined()
  })
})

describe("snippetRuns", () => {
  it("keeps short text whole, collapses whitespace and highlights ranges", () => {
    expect(text(snippetRuns("  please\n\ndeploy   it ", [[10, 16]]))).toBe("please [deploy] it")
  })

  it("cuts around the first match with ellipses", () => {
    const value = `${"a".repeat(50)} deploy ${"b".repeat(200)}`
    const runs = snippetRuns(value, [[51, 57]])
    const rendered = text(runs)
    expect(rendered.startsWith("…")).toBe(true)
    expect(rendered.endsWith("…")).toBe(true)
    expect(rendered).toContain("[deploy]")
    expect(rendered.indexOf("[deploy]")).toBe(1 + 24)
  })

  it("highlights several ranges, merging overlaps, and never splits a surrogate pair", () => {
    expect(text(snippetRuns("ship 🚀 now ship", [[5, 6], [12, 16], [13, 14]]))).toBe("ship [🚀] now [ship]")
    expect(text(snippetRuns("abc", [[5, 9], [-3, 1]]))).toBe("[a]bc")
  })

  it("starts the text when nothing matched, and handles empty input", () => {
    expect(text(snippetRuns("x".repeat(200), []))).toBe(`${"x".repeat(120)}…`)
    expect(snippetRuns("", [[0, 1]])).toEqual([])
  })

  it("keeps right-to-left text in logical order", () => {
    expect(text(snippetRuns("سلام دنیا", [[5, 9]]))).toBe("سلام [دنیا]")
  })
})

describe("the list window", () => {
  const { rowHeight, inset, overscan } = findListMetrics

  it("renders the rows near the viewport, with spacers for the rest", () => {
    const view = listWindow({ scrollTop: 0, viewportHeight: rowHeight * 7, count: 4000 })
    expect(view.start).toBe(0)
    expect(view.end).toBe(8 + overscan)
    expect(view.before).toBe(0)
    expect(view.after).toBe((4000 - view.end) * rowHeight)
    const far = listWindow({ scrollTop: inset + 1000 * rowHeight, viewportHeight: rowHeight * 7, count: 4000 })
    expect(far.start).toBe(1000 - overscan)
    expect(far.before + (far.end - far.start) * rowHeight + far.after).toBe(4000 * rowHeight)
    expect(listWindow({ scrollTop: 0, viewportHeight: 300, count: 0 })).toEqual({ start: 0, end: 0, before: 0, after: 0 })
  })

  it("reveals a row above or below the viewport and leaves a visible one", () => {
    const viewportHeight = rowHeight * 7 + inset * 2
    expect(revealRow({ index: 2, scrollTop: 0, viewportHeight })).toBeUndefined()
    expect(revealRow({ index: 7, scrollTop: 0, viewportHeight })).toBe(inset + 8 * rowHeight + inset - viewportHeight)
    expect(revealRow({ index: 3, scrollTop: 10 * rowHeight, viewportHeight })).toBe(3 * rowHeight)
  })

  it("is at most seven rows tall plus the footer and inset", () => {
    expect(listHeight(2, false)).toBe(2 * rowHeight + inset * 2)
    expect(listHeight(500, true)).toBe(7 * rowHeight + findListMetrics.footerHeight + inset * 2)
  })
})

describe("shortcut hints", () => {
  it("formats per platform", () => {
    expect(shortcutHint(findShortcuts.findNext, { os: "mac", surface: "browser" })).toBe("⌘G")
    expect(shortcutHint(findShortcuts.findPrevious, { os: "mac", surface: "browser" })).toBe("⇧⌘G")
    expect(shortcutHint(findShortcuts.findNext, { os: "windows", surface: "browser" })).toBe("Ctrl+G")
    expect(ariaShortcut(findShortcuts.findPrevious, { os: "mac", surface: "desktop" })).toBe("Meta+Shift+G")
    expect(ariaShortcut(findShortcuts.find, { os: "linux", surface: "browser" })).toBe("Control+F")
  })
})

describe("chatSelectionText", () => {
  const element = (inside: boolean, editable = false) => ({
    inside,
    closest: (selector: string) => (editable && selector.includes("input") ? {} : null),
  })
  const root = { contains: (node: unknown) => (node as { inside?: boolean } | null)?.inside === true }
  const doc = (anchor: unknown, focus: unknown, value = "deploy plan", collapsed = false) => ({
    getSelection: () => ({ isCollapsed: collapsed, rangeCount: 1, anchorNode: anchor, focusNode: focus, toString: () => value }),
  })

  it("returns a selection inside the chat's messages", () => {
    expect(chatSelectionText(doc(element(true), element(true)), root)).toBe("deploy plan")
  })

  it("ignores selections outside the chat, in a field, collapsed or blank", () => {
    expect(chatSelectionText(doc(element(true), element(false)), root)).toBeUndefined()
    expect(chatSelectionText(doc(element(true, true), element(true)), root)).toBeUndefined()
    expect(chatSelectionText(doc(element(true), element(true), "x", true), root)).toBeUndefined()
    expect(chatSelectionText(doc(element(true), element(true), "  "), root)).toBeUndefined()
    expect(chatSelectionText(undefined, root)).toBeUndefined()
  })

  it("looks through a text node to its parent element", () => {
    const parent = element(true, true)
    const textNode = { inside: true, parentElement: parent }
    expect(chatSelectionText(doc(textNode, textNode), root)).toBeUndefined()
  })
})
