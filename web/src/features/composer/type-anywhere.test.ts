import { signal } from "@inline/reactive"
import { describe, expect, it } from "vitest"
import type { ComposerModel } from "./model"
import { listenTypeAnywhere } from "./type-anywhere"

/** A document stand-in that records listeners, and a composer stand-in that records focus. */
const setup = () => {
  const listeners = new Map<string, (event: unknown) => void>()
  const doc = {
    addEventListener: (type: string, fn: (event: unknown) => void) => listeners.set(type, fn),
    removeEventListener: (type: string) => listeners.delete(type),
  } as unknown as Document
  const focused = signal(false)
  let focusCalls = 0
  const model = {
    focused,
    focus: () => {
      focusCalls += 1
      focused.set(true)
      return true
    },
  } as unknown as ComposerModel
  const press = (key: string, extra: Record<string, unknown> = {}) =>
    listeners.get("keydown")?.({ key, ctrlKey: false, metaKey: false, altKey: false, target: null, ...extra })
  return { doc, model, focused, press, listeners, focusCalls: () => focusCalls }
}

describe("type anywhere", () => {
  it("focuses the active composer for a typed character, once", () => {
    const t = setup()
    const keys: string[] = []
    const stop = listenTypeAnywhere(t.doc, () => t.model, (key) => keys.push(key))
    t.press("h")
    t.press("i")
    expect(t.focusCalls()).toBe(1)
    expect(keys).toEqual(["h"])
    stop()
    expect(t.listeners.size).toBe(0)
  })

  it("ignores shortcuts, editable targets, and having no composer", () => {
    const t = setup()
    let active: ComposerModel | null = null
    const stop = listenTypeAnywhere(t.doc, () => active)
    t.press("a")
    active = t.model
    t.press("k", { metaKey: true })
    t.press("a", { target: { closest: () => null, isContentEditable: true, localName: "div" } })
    t.press("a", { target: { closest: () => null, isContentEditable: false, localName: "input", type: "text" } })
    expect(t.focusCalls()).toBe(0)
    t.press("a", { target: { closest: () => null, isContentEditable: false, localName: "input", type: "checkbox" } })
    expect(t.focusCalls()).toBe(1)
    stop()
  })
})
