import { describe, expect, it } from "vitest"
import { signal, type Signal } from "@inline/reactive"
import { CommandRegistry, KeyboardDispatcher, allPlatforms, comboId, reservedComboIds, type KeyEventLike, type Platform } from "@inline/view"
import { findCommandIds, registerFindCommands, type FindCommandTarget } from "./commands"

const mac: Platform = { os: "mac", surface: "browser" }
const windows: Platform = { os: "windows", surface: "browser" }

type FakeTarget = FindCommandTarget & {
  readonly calls: string[]
  readonly open$: Signal<boolean>
  readonly focused$: Signal<boolean>
  readonly older$: Signal<boolean>
  readonly newer$: Signal<boolean>
}

const fakeTarget = (): FakeTarget => {
  const calls: string[] = []
  const open$ = signal(false)
  const focused$ = signal(false)
  const older$ = signal(false)
  const newer$ = signal(false)
  return {
    calls,
    open$,
    focused$,
    older$,
    newer$,
    isOpen: open$,
    fieldFocused: focused$,
    canGoOlder: older$,
    canGoNewer: newer$,
    open: (options) => {
      calls.push(options?.seed !== undefined ? `open:${options.seed}` : "open")
      open$.set(true)
    },
    next: () => calls.push("next"),
    previous: () => calls.push("previous"),
  }
}

const key = (k: string, mods: Partial<KeyEventLike> = {}, target: unknown = { tagName: "DIV" }) => {
  let prevented = false
  const event: KeyEventLike = {
    key: k,
    ctrlKey: false,
    metaKey: false,
    altKey: false,
    shiftKey: false,
    target,
    ...mods,
    preventDefault: () => {
      prevented = true
    },
  }
  return { event, prevented: () => prevented }
}

const setup = (platform: Platform = mac, readSelection?: () => string | undefined) => {
  const registry = new CommandRegistry()
  const target = signal<FindCommandTarget | undefined>(undefined)
  const dispose = registerFindCommands(registry, { target, ...(readSelection ? { readSelection } : {}) })
  const keyboard = new KeyboardDispatcher({ registry, platform })
  const press = (k: string, mods: Partial<KeyEventLike> = {}, from?: unknown) => {
    const pressed = key(k, mods, from)
    const resolution = keyboard.handleKeyDown(pressed.event)
    return { resolution, prevented: pressed.prevented() }
  }
  return { registry, target, dispose, keyboard, press }
}

const input = { tagName: "INPUT", type: "text" }

describe("find commands", () => {
  it("are disabled without a chat, so the browser keeps Mod+F", () => {
    const { press, registry } = setup()
    const result = press("f", { metaKey: true })
    expect(result.resolution).toEqual({ kind: "none", reason: "disabled" })
    expect(result.prevented).toBe(false)
    expect(registry.isEnabled(findCommandIds.findNext)).toBe(false)
  })

  it("Mod+F opens the bar seeded with the selection, from the composer too", () => {
    let selection: string | undefined = "deploy plan"
    const { press, target } = setup(mac, () => selection)
    const chat = fakeTarget()
    target.set(chat)
    expect(press("f", { metaKey: true }).prevented).toBe(true)
    selection = undefined
    chat.open$.set(false)
    expect(press("f", { metaKey: true }, input).prevented).toBe(true)
    expect(chat.calls).toEqual(["open:deploy plan", "open"])
  })

  it("Mod+F focuses an open bar, and falls through to the browser while the field has focus", () => {
    const { press, target } = setup()
    const chat = fakeTarget()
    target.set(chat)
    chat.open$.set(true)
    expect(press("f", { metaKey: true }).prevented).toBe(true)
    chat.focused$.set(true)
    const second = press("f", { metaKey: true }, input)
    expect(second.prevented).toBe(false)
    expect(second.resolution).toEqual({ kind: "none", reason: "disabled" })
    expect(chat.calls).toEqual(["open"])
  })

  it("Mod+G opens the bar when closed, steps older when open, and falls through at the oldest match", () => {
    const { press, target } = setup()
    const chat = fakeTarget()
    target.set(chat)
    expect(press("g", { metaKey: true }).prevented).toBe(true)
    expect(chat.calls).toEqual(["open"])
    chat.older$.set(true)
    chat.focused$.set(true)
    expect(press("g", { metaKey: true }, input).prevented).toBe(true)
    expect(chat.calls).toEqual(["open", "next"])
    chat.older$.set(false)
    expect(press("g", { metaKey: true }, input).prevented).toBe(false)
  })

  it("Mod+Shift+G steps newer only while open with a newer match", () => {
    const { press, target } = setup()
    const chat = fakeTarget()
    target.set(chat)
    chat.newer$.set(true)
    expect(press("g", { metaKey: true, shiftKey: true }).prevented).toBe(false)
    chat.open$.set(true)
    expect(press("g", { metaKey: true, shiftKey: true }).prevented).toBe(true)
    expect(chat.calls).toEqual(["previous"])
  })

  it("uses Ctrl on Windows and also F3 and Shift+F3", () => {
    const { press, target } = setup(windows)
    const chat = fakeTarget()
    target.set(chat)
    chat.open$.set(true)
    chat.older$.set(true)
    chat.newer$.set(true)
    press("f", { ctrlKey: true })
    press("g", { ctrlKey: true })
    press("F3")
    press("F3", { shiftKey: true })
    press("g", { ctrlKey: true, shiftKey: true })
    expect(chat.calls).toEqual(["open", "next", "next", "previous", "previous"])
  })

  it("binds nothing the browser or the OS owns, and nothing twice", () => {
    const { registry } = setup()
    for (const platform of allPlatforms) {
      const reserved = reservedComboIds(platform)
      for (const id of Object.values(findCommandIds)) {
        for (const combo of registry.get(id)!.shortcutsFor(platform)) expect(reserved.has(comboId(combo))).toBe(false)
      }
      expect(registry.conflicts(platform)).toEqual([])
    }
  })

  it("unregisters", () => {
    const { registry, dispose } = setup()
    dispose()
    expect(registry.commands.get()).toEqual([])
  })
})
