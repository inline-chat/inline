import { describe, expect, it } from "vitest"
import { escapeLeavesComposer, isTypingKey, sendErrorText, sendHint, sendShortcut, shouldFocusForKey, type KeyFacts } from "./text"

const key = (k: string, mods: Partial<KeyFacts & { shiftKey: boolean }> = {}) => ({
  key: k,
  ctrlKey: false,
  metaKey: false,
  altKey: false,
  shiftKey: false,
  ...mods,
})

describe("send key hint", () => {
  it("names the keys for each preference and platform", () => {
    expect(sendHint("enter", "mac")).toBe("↩ to send, ⇧↩ for a new line")
    expect(sendHint("modEnter", "mac")).toBe("⌘↩ to send")
    expect(sendHint("enter", "other")).toBe("Enter to send, Shift+Enter for a new line")
    expect(sendHint("modEnter", "other")).toBe("Ctrl+Enter to send")
    expect(sendShortcut("enter", "mac")).toBe("Enter")
    expect(sendShortcut("modEnter", "mac")).toBe("Meta+Enter")
    expect(sendShortcut("modEnter", "other")).toBe("Control+Enter")
  })
})

describe("send errors", () => {
  it("explains storage, uncertain and unknown failures and always keeps the text", () => {
    expect(sendErrorText("storageFull")).toMatch(/storage/)
    expect(sendErrorText("storage-full")).toBe(sendErrorText("storageFull"))
    expect(sendErrorText("notSignedIn")).toMatch(/signed out/)
    expect(sendErrorText("failed")).toMatch(/confirm/)
    expect(sendErrorText("anything")).toMatch(/Couldn't send/)
    for (const reason of ["storageFull", "notSignedIn", "invalid", "server", "unsupported", "unavailable", "failed", "uncertain", "x"]) {
      expect(sendErrorText(reason)).toMatch(/still here/)
    }
  })
})

describe("type anywhere to focus", () => {
  const outside = { targetIsEditable: false, composerFocused: false }

  it("takes one typed character in any script", () => {
    for (const k of ["a", "Z", "7", "?", "ش", "あ", "é", "€"]) expect(shouldFocusForKey(key(k), outside)).toBe(true)
    expect(shouldFocusForKey(key("A", { shiftKey: true }), outside)).toBe(true)
  })

  it("leaves shortcuts, navigation, Space and compositions alone", () => {
    for (const k of ["Enter", "ArrowUp", "Tab", "Escape", "F5", "Dead", "Process", " ", "Unidentified"]) {
      expect(shouldFocusForKey(key(k), outside)).toBe(false)
    }
    expect(shouldFocusForKey(key("k", { metaKey: true }), outside)).toBe(false)
    expect(shouldFocusForKey(key("k", { ctrlKey: true }), outside)).toBe(false)
    expect(shouldFocusForKey(key("f", { altKey: true }), outside)).toBe(false)
    expect(shouldFocusForKey(key("a", { isComposing: true }), outside)).toBe(false)
    expect(shouldFocusForKey(key("a", { defaultPrevented: true }), outside)).toBe(false)
  })

  it("lets Option and AltGr characters through", () => {
    expect(shouldFocusForKey(key("é", { altKey: true }), outside)).toBe(true)
    expect(shouldFocusForKey(key("@", { altKey: true, ctrlKey: true }), outside)).toBe(true)
  })

  it("does nothing when focus is already in a field or the composer", () => {
    expect(shouldFocusForKey(key("a"), { targetIsEditable: true, composerFocused: false })).toBe(false)
    expect(shouldFocusForKey(key("a"), { targetIsEditable: false, composerFocused: true })).toBe(false)
  })

  it("treats only single characters as typing", () => {
    expect(isTypingKey("a")).toBe(true)
    expect(isTypingKey("😀")).toBe(true)
    expect(isTypingKey("ab")).toBe(false)
    expect(isTypingKey("")).toBe(false)
    expect(isTypingKey("\u0007")).toBe(false)
  })
})

describe("Escape in the composer", () => {
  it("leaves only an empty composer, when nothing else took the key", () => {
    expect(escapeLeavesComposer(key("Escape"), { empty: true })).toBe(true)
    expect(escapeLeavesComposer(key("Escape"), { empty: false })).toBe(false)
    expect(escapeLeavesComposer(key("Escape", { defaultPrevented: true }), { empty: true })).toBe(false)
    expect(escapeLeavesComposer(key("Escape", { isComposing: true }), { empty: true })).toBe(false)
    expect(escapeLeavesComposer(key("Escape", { shiftKey: true }), { empty: true })).toBe(false)
    expect(escapeLeavesComposer(key("Enter"), { empty: true })).toBe(false)
  })
})
