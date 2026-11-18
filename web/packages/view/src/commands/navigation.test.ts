import { chatId } from "@inline/ids"
import { signal } from "@inline/reactive"
import { describe, expect, test } from "vitest"
import { createMemoryHistory } from "../workspace/history"
import { bindWorkspaceToHistory } from "../workspace/history-binding"
import { Workspace } from "../workspace/workspace"
import { KeyboardDispatcher } from "./keyboard"
import { navigationCommandIds as ids, registerNavigationCommands, type FocusRegion } from "./navigation"
import { allPlatforms, type Platform } from "./platform"
import { buildShortcutReference, buildShortcutReferences } from "./reference"
import { CommandRegistry } from "./registry"
import { isReservedShortcut, reservedComboIds } from "./reserved"
import { comboId, type KeyEventLike } from "./shortcut"

const chat = (id: string) => ({ kind: "chat", chatId: chatId(id) }) as const

const setup = (options: { history?: boolean } = {}) => {
  const workspace = new Workspace({ createId: () => "ws", initial: chat("1") })
  const memory = createMemoryHistory("/")
  const binding = options.history ? bindWorkspaceToHistory(workspace, memory) : undefined
  const calls: string[] = []
  const canSelect = signal(true)
  const registry = new CommandRegistry()
  const unregister = registerNavigationCommands(registry, {
    workspace,
    history: binding,
    selectAdjacentChat: (direction) => calls.push(`chat ${direction}`),
    canSelectAdjacentChat: canSelect,
    focusRegion: (region: FocusRegion) => calls.push(`focus ${region}`),
    openQuickSearch: () => calls.push("quickSearch"),
    toggleSidebar: () => calls.push("toggleSidebar"),
  })
  return { workspace, memory, registry, calls, canSelect, unregister }
}

const key = (k: string, code: string, init: Partial<KeyEventLike> = {}): KeyEventLike => ({
  key: k,
  code,
  ctrlKey: false,
  metaKey: false,
  altKey: false,
  shiftKey: false,
  ...init,
})

describe("navigation commands", () => {
  test("back and forward act on the focused pane and follow its state", () => {
    const { workspace, registry } = setup()
    expect(registry.isEnabled(ids.back)).toBe(false)
    workspace.open(chat("2"))
    expect(registry.isEnabled(ids.back)).toBe(true)
    expect(registry.run(ids.back)).toBe(true)
    expect(workspace.focusedDestination.peek()).toEqual(chat("1"))
    expect(registry.isEnabled(ids.back)).toBe(false)
    expect(registry.run(ids.back)).toBe(false)
    expect(registry.run(ids.forward)).toBe(true)
    expect(workspace.focusedDestination.peek()).toEqual(chat("2"))
  })

  test("with a history binding, back moves the browser too", () => {
    const { workspace, registry, memory } = setup({ history: true })
    workspace.open(chat("2"))
    registry.run(ids.back)
    expect(memory.index()).toBe(0)
    expect(workspace.focusedDestination.peek()).toEqual(chat("1"))
  })

  test("injected handlers run for chat selection, focus, search and sidebar", () => {
    const { registry, calls, canSelect } = setup()
    registry.run(ids.previousChat)
    registry.run(ids.nextChat)
    registry.run(ids.focusSidebar)
    registry.run(ids.focusComposer)
    registry.run(ids.quickSearch)
    registry.run(ids.toggleSidebar)
    canSelect.set(false)
    expect(registry.run(ids.nextChat)).toBe(false)
    expect(calls).toEqual(["chat -1", "chat 1", "focus sidebar", "focus composer", "quickSearch", "toggleSidebar"])
  })

  test("settings opens the settings destination by default", () => {
    const { workspace, registry } = setup()
    registry.run(ids.settings)
    expect(workspace.focusedDestination.peek()).toEqual({ kind: "settings" })
  })

  test("close pane is enabled only with more than one pane", () => {
    const { workspace, registry } = setup()
    expect(registry.isEnabled(ids.closePane)).toBe(false)
    workspace.open(chat("2"), { intent: "otherPane" })
    expect(registry.run(ids.closePane)).toBe(true)
    expect(workspace.panes.peek()).toHaveLength(1)
  })

  test("Mac app shortcuts drive the commands through the dispatcher", () => {
    const { workspace, registry, calls } = setup()
    const dispatcher = new KeyboardDispatcher({ registry, platform: { os: "mac", surface: "desktop" } })
    workspace.open(chat("2"))
    dispatcher.handleKeyDown(key("[", "BracketLeft", { metaKey: true }))
    expect(workspace.focusedDestination.peek()).toEqual(chat("1"))
    dispatcher.handleKeyDown(key("]", "BracketRight", { metaKey: true }))
    expect(workspace.focusedDestination.peek()).toEqual(chat("2"))
    const composer = { tagName: "DIV", isContentEditable: true }
    dispatcher.handleKeyDown(key("k", "KeyK", { ctrlKey: true, target: composer }))
    dispatcher.handleKeyDown(key("n", "KeyN", { ctrlKey: true, target: composer }))
    dispatcher.handleKeyDown(key("ArrowDown", "ArrowDown", { altKey: true, repeat: true, target: composer }))
    dispatcher.handleKeyDown(key("k", "KeyK", { metaKey: true, target: composer }))
    dispatcher.handleKeyDown(key("s", "KeyS", { metaKey: true }))
    // Escape focuses the composer only from the message list.
    dispatcher.handleKeyDown(key("Escape", "Escape"))
    dispatcher.setFocusScopes(["timeline"])
    dispatcher.handleKeyDown(key("Escape", "Escape"))
    expect(calls).toEqual(["chat -1", "chat 1", "chat 1", "quickSearch", "toggleSidebar", "focus composer"])
  })

  test("unregister removes them all", () => {
    const { registry, unregister } = setup()
    unregister()
    expect(registry.commands.peek()).toEqual([])
  })
})

describe("reserved shortcuts", () => {
  test.each(allPlatforms.map((p) => [`${p.surface} ${p.os}`, p] as const))(
    "no command binds a shortcut the browser or OS owns (%s)",
    (_label, platform: Platform) => {
      const { registry } = setup()
      const reserved = reservedComboIds(platform)
      const offending = [...registry.bindings(platform).keys()].filter((id) => reserved.has(id))
      expect(offending).toEqual([])
    },
  )

  test.each(allPlatforms.map((p) => [`${p.surface} ${p.os}`, p] as const))("no conflicts within a scope (%s)", (_l, p) => {
    expect(setup().registry.conflicts(p)).toEqual([])
  })

  test("Windows and Linux never bind the Windows or Super key", () => {
    const { registry } = setup()
    for (const platform of allPlatforms.filter((p) => p.os !== "mac")) {
      for (const bindings of registry.bindings(platform).values()) {
        for (const binding of bindings) expect(binding.combo.meta).toBe(false)
      }
    }
  })

  test("the deny-list holds the shortcuts a browser tab cannot bind", () => {
    const mac: Platform = { os: "mac", surface: "browser" }
    const win: Platform = { os: "windows", surface: "browser" }
    for (const text of ["Mod+T", "Mod+N", "Mod+W", "Mod+Shift+T", "Mod+1", "Mod+9", "Ctrl+Tab", "Mod+L", "Mod+R", "Mod+Q"]) {
      expect(isReservedShortcut(text, mac) || isReservedShortcut(text, { os: "mac", surface: "desktop" })).toBe(true)
    }
    for (const text of ["Ctrl+T", "Ctrl+N", "Ctrl+W", "Ctrl+5", "Alt+ArrowLeft", "F5", "Ctrl+Shift+I", "Alt+F4"]) {
      expect(isReservedShortcut(text, win)).toBe(true)
    }
    // The desktop app owns its own tabs and windows.
    expect(isReservedShortcut("Mod+W", { os: "mac", surface: "desktop" })).toBe(false)
    // Pages may take these over deliberately.
    expect(isReservedShortcut("Mod+K", mac)).toBe(false)
    expect(isReservedShortcut("Mod+S", win)).toBe(false)
  })

  test("the browser tab variant leaves out what the browser owns, and nothing else", () => {
    const { registry } = setup()
    const browserMac = buildShortcutReference(registry, { os: "mac", surface: "browser" })
    const keysOf = (ref: typeof browserMac, id: string) =>
      ref.categories.flatMap((c) => c.commands).find((c) => c.id === id)?.keys.map((k) => k.display)
    expect(keysOf(browserMac, ids.back)).toEqual([])
    expect(keysOf(browserMac, ids.closePane)).toEqual([])
    expect(keysOf(browserMac, ids.settings)).toEqual([])
    expect(keysOf(browserMac, ids.quickSearch)).toEqual(["⌘K"])
    expect(keysOf(browserMac, ids.previousChat)).toEqual(["⌥↑", "⌃K", "⌃P"])
    const browserWindows = buildShortcutReference(registry, { os: "windows", surface: "browser" })
    expect(keysOf(browserWindows, ids.settings)).toEqual(["Ctrl+,"])
    expect(keysOf(browserWindows, ids.focusSidebar)).toEqual([])
  })
})

describe("shortcut reference", () => {
  test("groups commands by platform and category as plain data", () => {
    const { registry } = setup()
    const references = buildShortcutReferences(registry)
    expect(references.map((r) => r.key)).toEqual([
      "desktop-mac",
      "desktop-windows",
      "desktop-linux",
      "browser-mac",
      "browser-windows",
      "browser-linux",
    ])
    const mac = references[0]
    expect(mac?.label).toBe("Mac app")
    expect(mac?.categories.map((c) => c.title)).toEqual(["Inline", "Navigation", "View", "Window"])
    const navigation = mac?.categories.find((c) => c.category === "navigation")
    expect(navigation?.commands.find((c) => c.id === ids.back)).toEqual({
      id: ids.back,
      title: "Back",
      scope: "global",
      keys: [{ combo: comboId({ key: "[", ctrl: false, meta: true, alt: false, shift: false }), display: "⌘[", accelerator: "Cmd+[" }],
    })
    // Plain data: survives structured cloning and JSON.
    expect(JSON.parse(JSON.stringify(references))).toEqual(references)
  })

  test("can leave out commands without a shortcut", () => {
    const { registry } = setup()
    const reference = buildShortcutReference(registry, { os: "windows", surface: "browser" }, { boundOnly: true })
    const listed = reference.categories.flatMap((c) => c.commands.map((cmd) => cmd.id))
    expect(listed).not.toContain(ids.back)
    expect(listed).not.toContain(ids.focusSidebar)
    expect(listed).toContain(ids.quickSearch)
  })
})

describe("registry", () => {
  test("rejects duplicate IDs and malformed shortcuts at registration", () => {
    const registry = new CommandRegistry()
    registry.register({ id: "a", title: "A", category: "app", run: () => {} })
    expect(() => registry.register({ id: "a", title: "A", category: "app", run: () => {} })).toThrow()
    expect(() =>
      registry.register({ id: "b", title: "B", category: "app", shortcuts: { browser: { mac: "Mod+Nope" } }, run: () => {} }),
    ).toThrow()
    expect(registry.get("b")).toBeUndefined()
  })

  test("conflicts in one scope are reported", () => {
    const registry = new CommandRegistry()
    registry.register({ id: "a", title: "A", category: "app", shortcuts: { default: "Mod+K" }, run: () => {} })
    registry.register({ id: "b", title: "B", category: "app", shortcuts: { default: "Mod+K" }, run: () => {} })
    registry.register({ id: "c", title: "C", category: "app", scope: "composer", shortcuts: { default: "Mod+K" }, run: () => {} })
    expect(registry.conflicts({ os: "mac", surface: "desktop" })).toEqual([
      { comboId: "Meta+k", scope: "global", commandIds: ["a", "b"] },
    ])
  })

  test("the command list is a signal", () => {
    const registry = new CommandRegistry()
    const seen: number[] = []
    seen.push(registry.commands.get().length)
    const dispose = registry.register({ id: "a", title: "A", category: "app", run: () => {} })
    seen.push(registry.commands.get().length)
    dispose()
    seen.push(registry.commands.get().length)
    expect(seen).toEqual([0, 1, 0])
  })
})
