import { describe, expect, test } from "vitest"
import { ariaKeyShortcuts, ariaKeyShortcutsFromHint } from "./shortcuts"

describe("aria-keyshortcuts", () => {
  test("from a combo: modifiers by the spec's names, the key as KeyboardEvent.key, letters upper case", () => {
    expect(ariaKeyShortcuts({ key: "e", meta: true })).toBe("Meta+E")
    expect(ariaKeyShortcuts({ key: "e", ctrl: true, shift: true })).toBe("Control+Shift+E")
    expect(ariaKeyShortcuts({ key: "Backspace", meta: true })).toBe("Meta+Backspace")
    expect(ariaKeyShortcuts({ key: "ArrowUp", alt: true })).toBe("Alt+ArrowUp")
    expect(ariaKeyShortcuts({ key: " ", ctrl: true })).toBe("Control+Space")
    expect(ariaKeyShortcuts({ key: "r" })).toBe("R")
  })

  test("from the registry's Mac hints", () => {
    expect(ariaKeyShortcutsFromHint("⌘E")).toBe("Meta+E")
    expect(ariaKeyShortcutsFromHint("⌘⌫")).toBe("Meta+Backspace")
    expect(ariaKeyShortcutsFromHint("⇧⌘Z")).toBe("Shift+Meta+Z")
    expect(ariaKeyShortcutsFromHint("⌃⌥↑")).toBe("Control+Alt+ArrowUp")
    expect(ariaKeyShortcutsFromHint("↑")).toBe("ArrowUp")
    expect(ariaKeyShortcutsFromHint("⌘Space")).toBe("Meta+Space")
  })

  test("from the registry's hints elsewhere", () => {
    expect(ariaKeyShortcutsFromHint("Ctrl+E")).toBe("Control+E")
    expect(ariaKeyShortcutsFromHint("Ctrl+Shift+Z")).toBe("Control+Shift+Z")
    expect(ariaKeyShortcutsFromHint("Alt+Up")).toBe("Alt+ArrowUp")
    expect(ariaKeyShortcutsFromHint("Ctrl+Backspace")).toBe("Control+Backspace")
    expect(ariaKeyShortcutsFromHint("Win+X")).toBe("Meta+X")
    expect(ariaKeyShortcutsFromHint("Ctrl++")).toBe("Control++")
    expect(ariaKeyShortcutsFromHint("R")).toBe("R")
  })

  test("text that is not a shortcut gives nothing", () => {
    expect(ariaKeyShortcutsFromHint("")).toBeUndefined()
    expect(ariaKeyShortcutsFromHint("Hello+World")).toBeUndefined()
    expect(ariaKeyShortcutsFromHint("⌘")).toBeUndefined()
  })
})
