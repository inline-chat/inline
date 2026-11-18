import { signal } from "@inline/reactive"
import { describe, expect, test } from "vitest"
import { canBeTyping, isTextInputTarget, KeyboardDispatcher } from "./keyboard"
import type { Platform } from "./platform"
import { CommandRegistry, type CommandSpec } from "./registry"
import { parseCombo, type KeyEventLike } from "./shortcut"

const mac: Platform = { os: "mac", surface: "desktop" }
const macBrowser: Platform = { os: "mac", surface: "browser" }
const windows: Platform = { os: "windows", surface: "desktop" }
const windowsBrowser: Platform = { os: "windows", surface: "browser" }
const linux: Platform = { os: "linux", surface: "desktop" }

const textarea = { tagName: "TEXTAREA" }
const editor = { tagName: "DIV", isContentEditable: true }
const button = { tagName: "BUTTON" }

type Event = KeyEventLike & { prevented: boolean }

const press = (
  keyName: string,
  init: Partial<Omit<KeyEventLike, "key">> = {},
): Event => {
  const code = /^[a-z]$/i.test(keyName)
    ? `Key${keyName.toUpperCase()}`
    : /^\d$/.test(keyName)
      ? `Digit${keyName}`
      : keyName === "["
        ? "BracketLeft"
        : keyName === ","
          ? "Comma"
          : keyName
  const event: Event = {
    key: keyName,
    code,
    ctrlKey: false,
    metaKey: false,
    altKey: false,
    shiftKey: false,
    prevented: false,
    preventDefault() {
      event.prevented = true
    },
    ...init,
  }
  return event
}

const setup = (platform: Platform, specs: Partial<CommandSpec>[], options: { onTypeToFocus?: () => void } = {}) => {
  const registry = new CommandRegistry()
  const ran: string[] = []
  for (const spec of specs) {
    const id = spec.id ?? "x"
    registry.register({ title: id, category: "navigation", run: () => ran.push(id), ...spec, id } as CommandSpec)
  }
  const dispatcher = new KeyboardDispatcher({ registry, platform, onTypeToFocus: options.onTypeToFocus })
  return { registry, dispatcher, ran }
}

describe("resolution per platform", () => {
  const specs: Partial<CommandSpec>[] = [
    { id: "search", shortcuts: { default: "Mod+K" } },
    { id: "prev", shortcuts: { default: "Alt+ArrowUp", mac: ["Alt+ArrowUp", "Ctrl+K"] } },
    { id: "back", shortcuts: { mac: "Mod+[", default: "Alt+ArrowLeft", browser: { default: [] } } },
  ]

  test("Mac: Cmd+K searches, Ctrl+K goes to the previous chat", () => {
    const { dispatcher, ran } = setup(mac, specs)
    dispatcher.handleKeyDown(press("k", { metaKey: true }))
    dispatcher.handleKeyDown(press("k", { ctrlKey: true }))
    dispatcher.handleKeyDown(press("ArrowUp", { altKey: true }))
    dispatcher.handleKeyDown(press("[", { metaKey: true }))
    expect(ran).toEqual(["search", "prev", "prev", "back"])
  })

  test("Windows: Ctrl+K searches; Cmd-style keys do nothing", () => {
    const { dispatcher, ran } = setup(windows, specs)
    dispatcher.handleKeyDown(press("k", { ctrlKey: true }))
    dispatcher.handleKeyDown(press("k", { metaKey: true }))
    dispatcher.handleKeyDown(press("ArrowLeft", { altKey: true }))
    dispatcher.handleKeyDown(press("[", { ctrlKey: true }))
    expect(ran).toEqual(["search", "back"])
  })

  test("Linux matches Windows conventions", () => {
    const { dispatcher, ran } = setup(linux, specs)
    dispatcher.handleKeyDown(press("k", { ctrlKey: true }))
    expect(ran).toEqual(["search"])
  })

  test("a browser tab drops what the browser owns", () => {
    for (const platform of [macBrowser, windowsBrowser]) {
      const { dispatcher, ran } = setup(platform, specs)
      const backKey = platform.os === "mac" ? press("[", { metaKey: true }) : press("ArrowLeft", { altKey: true })
      expect(dispatcher.handleKeyDown(backKey).kind).toBe("none")
      expect(backKey.prevented).toBe(false)
      dispatcher.handleKeyDown(press("k", platform.os === "mac" ? { metaKey: true } : { ctrlKey: true }))
      expect(ran).toEqual(["search"])
    }
  })

  test("extra modifiers do not match", () => {
    const { dispatcher, ran } = setup(mac, specs)
    dispatcher.handleKeyDown(press("k", { metaKey: true, shiftKey: true }))
    dispatcher.handleKeyDown(press("k", { metaKey: true, altKey: true }))
    expect(ran).toEqual([])
  })

  test("a matched key prevents the browser default; an unmatched one does not", () => {
    const { dispatcher } = setup(mac, specs)
    const hit = press("k", { metaKey: true })
    const miss = press("j", { metaKey: true })
    dispatcher.handleKeyDown(hit)
    dispatcher.handleKeyDown(miss)
    expect(hit.prevented).toBe(true)
    expect(miss.prevented).toBe(false)
  })

  test("an event another handler already prevented is left alone", () => {
    const { dispatcher, ran } = setup(mac, specs)
    dispatcher.handleKeyDown({ ...press("k", { metaKey: true }), defaultPrevented: true })
    expect(ran).toEqual([])
  })
})

describe("scopes", () => {
  const specs: Partial<CommandSpec>[] = [
    { id: "global.escape", shortcuts: { default: "Escape" } },
    { id: "timeline.escape", scope: "timeline", shortcuts: { default: "Escape" } },
    { id: "composer.escape", scope: "composer", shortcuts: { default: "Escape" }, whileTyping: "always" },
    { id: "menu.escape", scope: "menu", shortcuts: { default: "Escape" }, whileTyping: "always" },
    { id: "global.search", shortcuts: { default: "Mod+K" } },
    { id: "sidebar.delete", scope: "sidebar", shortcuts: { default: "Backspace" } },
  ]

  test("the focused region's command wins over global", () => {
    const { dispatcher, ran } = setup(mac, specs)
    dispatcher.handleKeyDown(press("Escape"))
    dispatcher.setFocusScopes(["timeline"])
    dispatcher.handleKeyDown(press("Escape"))
    dispatcher.setFocusScopes(["composer", "timeline"])
    dispatcher.handleKeyDown(press("Escape", { target: textarea }))
    expect(ran).toEqual(["global.escape", "timeline.escape", "composer.escape"])
  })

  test("a region's commands do not fire when it is not focused", () => {
    const { dispatcher, ran } = setup(mac, specs)
    dispatcher.handleKeyDown(press("Backspace"))
    dispatcher.setFocusScopes(["sidebar"])
    dispatcher.handleKeyDown(press("Backspace"))
    expect(ran).toEqual(["sidebar.delete"])
  })

  test("a layer wins over focus scopes, and closing it restores them", () => {
    const { dispatcher, ran } = setup(mac, specs)
    dispatcher.setFocusScopes(["timeline"])
    const close = dispatcher.pushLayer("menu")
    expect(dispatcher.activeScopes.peek()).toEqual(["menu", "timeline", "global"])
    dispatcher.handleKeyDown(press("Escape"))
    // A non-modal layer lets other keys through to lower scopes.
    dispatcher.handleKeyDown(press("k", { metaKey: true }))
    close()
    dispatcher.handleKeyDown(press("Escape"))
    expect(ran).toEqual(["menu.escape", "global.search", "timeline.escape"])
  })

  test("a modal layer blocks everything below it", () => {
    const { dispatcher, ran } = setup(mac, specs)
    dispatcher.setFocusScopes(["timeline"])
    const close = dispatcher.pushLayer("dialog", { modal: true })
    expect(dispatcher.activeScopes.peek()).toEqual(["dialog"])
    dispatcher.handleKeyDown(press("k", { metaKey: true }))
    dispatcher.handleKeyDown(press("Escape"))
    close()
    expect(dispatcher.activeScopes.peek()).toEqual(["timeline", "global"])
    expect(ran).toEqual([])
  })

  test("layers stack, newest first", () => {
    const { dispatcher } = setup(mac, specs)
    dispatcher.pushLayer("menu")
    dispatcher.pushLayer("submenu")
    expect(dispatcher.activeScopes.peek()).toEqual(["submenu", "menu", "global"])
  })

  test("a disabled command falls through to the next scope", () => {
    const enabled = signal(false)
    const { dispatcher, ran } = setup(mac, [
      { id: "timeline.escape", scope: "timeline", shortcuts: { default: "Escape" }, enabled },
      { id: "global.escape", shortcuts: { default: "Escape" } },
    ])
    dispatcher.setFocusScopes(["timeline"])
    dispatcher.handleKeyDown(press("Escape"))
    enabled.set(true)
    dispatcher.handleKeyDown(press("Escape"))
    expect(ran).toEqual(["global.escape", "timeline.escape"])
  })

  test("a disabled command with nothing below leaves the key to the browser", () => {
    const { dispatcher } = setup(mac, [{ id: "a", shortcuts: { default: "Mod+K" }, enabled: signal(false) }])
    const event = press("k", { metaKey: true })
    expect(dispatcher.handleKeyDown(event)).toEqual({ kind: "none", reason: "disabled" })
    expect(event.prevented).toBe(false)
  })
})

describe("text fields", () => {
  const specs: Partial<CommandSpec>[] = [
    { id: "letter", shortcuts: { default: "J" } },
    { id: "shifted", shortcuts: { default: "Shift+J" } },
    { id: "escape", shortcuts: { default: "Escape" } },
    { id: "search", shortcuts: { default: "Mod+K" } },
    { id: "prev", shortcuts: { default: "Alt+ArrowUp" } },
    { id: "alt-letter", shortcuts: { default: "Alt+J" } },
    { id: "altgr", shortcuts: { default: "Ctrl+Alt+Q" } },
    { id: "f-key", shortcuts: { default: "F2" } },
    { id: "never", shortcuts: { default: "Mod+J" }, whileTyping: "never" },
  ]

  test("a plain or shifted letter typed in a field is not a shortcut", () => {
    for (const target of [textarea, editor, { tagName: "input" }, { tagName: "INPUT", type: "search" }]) {
      const { dispatcher, ran } = setup(mac, specs)
      expect(dispatcher.handleKeyDown(press("j", { target })).kind).toBe("none")
      dispatcher.handleKeyDown(press("J", { target, shiftKey: true }))
      dispatcher.handleKeyDown(press("Escape", { target }))
      expect(ran).toEqual([])
    }
  })

  test("the same letters outside a field are shortcuts", () => {
    const { dispatcher, ran } = setup(mac, specs)
    dispatcher.handleKeyDown(press("j", { target: button }))
    dispatcher.handleKeyDown(press("J", { shiftKey: true, target: { tagName: "INPUT", type: "checkbox" } }))
    expect(ran).toEqual(["letter", "shifted"])
  })

  test("Cmd or Ctrl shortcuts, Alt with arrows and function keys work while typing", () => {
    const { dispatcher, ran } = setup(mac, specs)
    dispatcher.handleKeyDown(press("k", { metaKey: true, target: textarea }))
    dispatcher.handleKeyDown(press("ArrowUp", { altKey: true, target: textarea }))
    dispatcher.handleKeyDown(press("F2", { target: textarea }))
    dispatcher.handleKeyDown(press("j", { metaKey: true, target: textarea }))
    expect(ran).toEqual(["search", "prev", "f-key"])
  })

  test("Option with a letter types a character on Mac but not elsewhere", () => {
    const onMac = setup(mac, specs)
    onMac.dispatcher.handleKeyDown(press("∆", { code: "KeyJ", altKey: true, target: textarea }))
    expect(onMac.ran).toEqual([])
    const onWindows = setup(windows, specs)
    onWindows.dispatcher.handleKeyDown(press("j", { altKey: true, target: textarea }))
    expect(onWindows.ran).toEqual(["alt-letter"])
  })

  test("AltGr (Ctrl+Alt on Windows and Linux) is typing", () => {
    const { dispatcher, ran } = setup(windows, specs)
    dispatcher.handleKeyDown(press("@", { code: "KeyQ", ctrlKey: true, altKey: true, target: textarea }))
    dispatcher.handleKeyDown(
      press("q", { ctrlKey: true, altKey: true, target: textarea, getModifierState: (k) => k === "AltGraph" }),
    )
    expect(ran).toEqual([])
    dispatcher.handleKeyDown(press("q", { ctrlKey: true, altKey: true, target: button }))
    expect(ran).toEqual(["altgr"])
  })

  test("canBeTyping", () => {
    expect(canBeTyping(parseCombo("Mod+K", "mac"), mac)).toBe(false)
    expect(canBeTyping(parseCombo("Alt+K", "mac"), mac)).toBe(true)
    expect(canBeTyping(parseCombo("Alt+K", "windows"), windows)).toBe(false)
    expect(canBeTyping(parseCombo("Ctrl+Alt+K", "windows"), windows)).toBe(true)
    expect(canBeTyping(parseCombo("Ctrl+Alt+K", "mac"), mac)).toBe(false)
    expect(canBeTyping(parseCombo("Enter", "mac"), mac)).toBe(true)
    expect(canBeTyping(parseCombo("F2", "mac"), mac)).toBe(false)
  })

  test("text field detection", () => {
    expect(isTextInputTarget(textarea)).toBe(true)
    expect(isTextInputTarget(editor)).toBe(true)
    expect(isTextInputTarget({ tagName: "SELECT" })).toBe(true)
    expect(isTextInputTarget({ tagName: "INPUT", type: "email" })).toBe(true)
    expect(isTextInputTarget({ tagName: "INPUT", type: "radio" })).toBe(false)
    expect(isTextInputTarget(button)).toBe(false)
    expect(isTextInputTarget(null)).toBe(false)
    expect(isTextInputTarget(undefined)).toBe(false)
  })
})

describe("composition and repeat", () => {
  test("nothing fires during IME composition", () => {
    const { dispatcher, ran } = setup(mac, [{ id: "search", shortcuts: { default: "Mod+K" } }, { id: "esc", shortcuts: { default: "Escape" } }])
    for (const event of [
      press("k", { metaKey: true, isComposing: true }),
      press("Process", { code: "KeyK", metaKey: true }),
      press("Escape", { keyCode: 229 }),
    ]) {
      expect(dispatcher.handleKeyDown(event)).toEqual({ kind: "none", reason: "composing" })
      expect(event.prevented).toBe(false)
    }
    expect(ran).toEqual([])
  })

  test("a held key repeats only commands that allow it; other repeats are swallowed", () => {
    const { dispatcher, ran } = setup(mac, [
      { id: "next", shortcuts: { default: "Alt+ArrowDown" }, repeat: true },
      { id: "search", shortcuts: { default: "Mod+K" } },
    ])
    dispatcher.handleKeyDown(press("ArrowDown", { altKey: true }))
    dispatcher.handleKeyDown(press("ArrowDown", { altKey: true, repeat: true }))
    dispatcher.handleKeyDown(press("k", { metaKey: true }))
    const repeat = press("k", { metaKey: true, repeat: true })
    expect(dispatcher.handleKeyDown(repeat).kind).toBe("swallow")
    expect(repeat.prevented).toBe(true)
    expect(ran).toEqual(["next", "next", "search"])
  })
})

describe("type to focus", () => {
  test("a character typed outside a field asks the app to focus the composer", () => {
    let calls = 0
    const { dispatcher } = setup(mac, [{ id: "j", shortcuts: { default: "J" } }], { onTypeToFocus: () => calls++ })
    const typed = press("h", { target: button })
    expect(dispatcher.handleKeyDown(typed).kind).toBe("typeToFocus")
    // Not prevented, so the character reaches the newly focused composer.
    expect(typed.prevented).toBe(false)
    dispatcher.handleKeyDown(press("H", { shiftKey: true }))
    expect(calls).toBe(2)
    // Not for bound keys, fields, modified keys, space, named keys or under a modal layer.
    dispatcher.handleKeyDown(press("j"))
    dispatcher.handleKeyDown(press("h", { target: textarea }))
    dispatcher.handleKeyDown(press("h", { metaKey: true }))
    dispatcher.handleKeyDown(press(" ", { code: "Space" }))
    dispatcher.handleKeyDown(press("ArrowDown"))
    dispatcher.pushLayer("dialog", { modal: true })
    dispatcher.handleKeyDown(press("h"))
    expect(calls).toBe(2)
  })
})
