import { describe, expect, test } from "vitest"
import { detectOS, detectPlatform } from "./platform"
import {
  comboId,
  eventCombo,
  formatCombo,
  isComposingEvent,
  parseCombo,
  parseShortcut,
  ShortcutParseError,
  toAccelerator,
  type KeyEventLike,
} from "./shortcut"

const key = (init: Partial<KeyEventLike> & { key: string }): KeyEventLike => ({
  ctrlKey: false,
  metaKey: false,
  altKey: false,
  shiftKey: false,
  ...init,
})

describe("parse", () => {
  test.each([
    ["Mod+K", { key: "k", mod: true, ctrl: false, meta: false, alt: false, shift: false }],
    ["Alt+ArrowUp", { key: "ArrowUp", mod: false, ctrl: false, meta: false, alt: true, shift: false }],
    ["Ctrl+Shift+C", { key: "c", mod: false, ctrl: true, meta: false, alt: false, shift: true }],
    ["cmd+option+up", { key: "ArrowUp", mod: false, ctrl: false, meta: true, alt: true, shift: false }],
    ["Mod+[", { key: "[", mod: true, ctrl: false, meta: false, alt: false, shift: false }],
    ["Mod+Comma", { key: ",", mod: true, ctrl: false, meta: false, alt: false, shift: false }],
    ["Mod+,", { key: ",", mod: true, ctrl: false, meta: false, alt: false, shift: false }],
    ["Esc", { key: "Escape", mod: false, ctrl: false, meta: false, alt: false, shift: false }],
    ["Shift+Return", { key: "Enter", mod: false, ctrl: false, meta: false, alt: false, shift: true }],
    ["f12", { key: "F12", mod: false, ctrl: false, meta: false, alt: false, shift: false }],
    ["Mod+1", { key: "1", mod: true, ctrl: false, meta: false, alt: false, shift: false }],
  ])("%s", (text, parsed) => {
    expect(parseShortcut(text)).toEqual(parsed)
  })

  test.each(["", "Mod+", "+K", "Mod++", "Hyper+K", "Mod+Mod+K", "Mod+KK", "Mod+F25", "Mod+é"])("%j is rejected", (text) => {
    expect(() => parseShortcut(text)).toThrow(ShortcutParseError)
  })

  test("Mod is Cmd on Mac and Ctrl elsewhere; Ctrl is always Control", () => {
    expect(parseCombo("Mod+K", "mac")).toEqual({ key: "k", ctrl: false, meta: true, alt: false, shift: false })
    expect(parseCombo("Mod+K", "windows")).toEqual({ key: "k", ctrl: true, meta: false, alt: false, shift: false })
    expect(parseCombo("Mod+K", "linux")).toEqual({ key: "k", ctrl: true, meta: false, alt: false, shift: false })
    expect(parseCombo("Ctrl+K", "mac")).toEqual({ key: "k", ctrl: true, meta: false, alt: false, shift: false })
  })
})

describe("events", () => {
  test("letters match the character typed, so other layouts work", () => {
    // Dvorak: the key labelled K sends key "k" from a different physical key.
    expect(eventCombo(key({ key: "k", code: "KeyV", metaKey: true }))?.key).toBe("k")
    // Shift does not change the letter.
    expect(eventCombo(key({ key: "K", code: "KeyK", shiftKey: true }))?.key).toBe("k")
  })

  test("Option on Mac and non-Latin layouts fall back to the physical key", () => {
    expect(eventCombo(key({ key: "˚", code: "KeyK", altKey: true }))?.key).toBe("k")
    expect(eventCombo(key({ key: "л", code: "KeyK", ctrlKey: true }))?.key).toBe("k")
    expect(eventCombo(key({ key: "Dead", code: "KeyE", altKey: true }))?.key).toBe("e")
  })

  test("digits and punctuation match the physical key, so Shift does not change them", () => {
    expect(eventCombo(key({ key: "!", code: "Digit1", shiftKey: true }))?.key).toBe("1")
    expect(eventCombo(key({ key: "{", code: "BracketLeft", shiftKey: true, metaKey: true }))?.key).toBe("[")
    expect(eventCombo(key({ key: "<", code: "Comma", shiftKey: true }))?.key).toBe(",")
  })

  test("named keys, legacy names and space", () => {
    expect(eventCombo(key({ key: "ArrowUp", code: "ArrowUp", altKey: true }))?.key).toBe("ArrowUp")
    expect(eventCombo(key({ key: "Up" }))?.key).toBe("ArrowUp")
    expect(eventCombo(key({ key: "Esc" }))?.key).toBe("Escape")
    expect(eventCombo(key({ key: " ", code: "Space" }))?.key).toBe("Space")
    expect(eventCombo(key({ key: "F5", code: "F5" }))?.key).toBe("F5")
  })

  test("modifier-only presses are not combos", () => {
    for (const k of ["Shift", "Control", "Alt", "Meta", "AltGraph", "CapsLock"]) {
      expect(eventCombo(key({ key: k }))).toBeUndefined()
    }
  })

  test("events and parsed shortcuts produce the same ids", () => {
    const pairs: [string, KeyEventLike, "mac" | "windows"][] = [
      ["Mod+K", key({ key: "k", code: "KeyK", metaKey: true }), "mac"],
      ["Mod+K", key({ key: "k", code: "KeyK", ctrlKey: true }), "windows"],
      ["Alt+ArrowDown", key({ key: "ArrowDown", code: "ArrowDown", altKey: true }), "mac"],
      ["Ctrl+Shift+C", key({ key: "C", code: "KeyC", ctrlKey: true, shiftKey: true }), "windows"],
      ["Mod+]", key({ key: "]", code: "BracketRight", metaKey: true }), "mac"],
    ]
    for (const [text, event, os] of pairs) {
      const combo = eventCombo(event)
      expect(combo && comboId(combo)).toBe(comboId(parseCombo(text, os)))
    }
  })

  test("composition is detected three ways", () => {
    expect(isComposingEvent(key({ key: "a", isComposing: true }))).toBe(true)
    expect(isComposingEvent(key({ key: "Process" }))).toBe(true)
    expect(isComposingEvent(key({ key: "a", keyCode: 229 }))).toBe(true)
    expect(isComposingEvent(key({ key: "a", keyCode: 65 }))).toBe(false)
  })
})

describe("display", () => {
  test.each([
    ["Mod+K", "mac", "⌘K"],
    ["Mod+K", "windows", "Ctrl+K"],
    ["Alt+ArrowUp", "mac", "⌥↑"],
    ["Alt+ArrowUp", "linux", "Alt+Up"],
    ["Mod+Shift+C", "mac", "⇧⌘C"],
    ["Ctrl+Alt+Shift+Cmd+K", "mac", "⌃⌥⇧⌘K"],
    ["Mod+,", "windows", "Ctrl+,"],
    ["Escape", "windows", "Esc"],
  ] as const)("%s on %s is %s", (text, os, display) => {
    expect(formatCombo(parseCombo(text, os), os)).toBe(display)
  })

  test("Electron accelerators", () => {
    expect(toAccelerator(parseCombo("Mod+Shift+E", "mac"))).toBe("Cmd+Shift+E")
    expect(toAccelerator(parseCombo("Alt+ArrowUp", "windows"))).toBe("Alt+Up")
  })
})

describe("platform detection", () => {
  test.each([
    [{ userAgentData: { platform: "macOS" } }, "mac"],
    [{ platform: "MacIntel" }, "mac"],
    [{ userAgent: "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X)" }, "mac"],
    [{ userAgentData: { platform: "Windows" } }, "windows"],
    [{ platform: "Win32" }, "windows"],
    [{ platform: "Linux x86_64" }, "linux"],
    [{ userAgent: "Mozilla/5.0 (X11; CrOS x86_64 14541.0.0)" }, "linux"],
    [{}, "windows"],
    [undefined, "windows"],
  ] as const)("%j is %s", (navigator, os) => {
    expect(detectOS(navigator)).toBe(os)
  })

  test("the surface comes from the host", () => {
    expect(detectPlatform({ navigator: { platform: "MacIntel" }, desktop: true })).toEqual({ os: "mac", surface: "desktop" })
    expect(detectPlatform({ navigator: { platform: "Win32" } })).toEqual({ os: "windows", surface: "browser" })
  })
})
