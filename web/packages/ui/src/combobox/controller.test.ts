// @vitest-environment happy-dom
import { afterEach, describe, expect, test } from "vitest"
import { createManualClock } from "../foundations/clock"
import { openLayerCount } from "../foundations/dismiss"
import type { ListboxOption } from "../listbox/controller"
import { click, h, mount, pointer, press } from "../testing/dom"
import { ComboboxController, defaultComboboxFilter } from "./controller"

const people: ListboxOption[] = [
  { id: "ada", label: "Ada Lovelace" },
  { id: "alan", label: "Alan Turing" },
  { id: "grace", label: "Grace Hopper" },
  { id: "linus", label: "Linus Torvalds", disabled: true },
]

const render = (combobox: ComboboxController) => {
  const input = mount(h("input")) as HTMLInputElement
  const popup = mount(h("div"))
  combobox.input.attach(input)
  combobox.popup.attach(popup)
  combobox.listbox.passiveRoot.attach(popup)
  const attached = new Set<string>()
  const renderOptions = () => {
    for (const option of combobox.results.peek()) {
      if (attached.has(option.id)) continue
      attached.add(option.id)
      const element = h("div", {}, option.label)
      popup.append(element)
      combobox.listbox.option(option.id).attach(element)
    }
  }
  renderOptions()
  const type = (text: string) => {
    input.value = text
    input.dispatchEvent(new Event("input", { bubbles: true }))
    renderOptions()
  }
  const option = (id: string) => document.getElementById(combobox.listbox.optionDomId(id))!
  return { input, popup, type, option, renderOptions }
}

afterEach(() => document.body.replaceChildren())

describe("default filter", () => {
  test("matches word prefixes, accent and case insensitive", () => {
    expect(defaultComboboxFilter({ id: "x", label: "Grace Hopper" }, "hop")).toBe(true)
    expect(defaultComboboxFilter({ id: "x", label: "Grace Hopper" }, "gr ho")).toBe(true)
    expect(defaultComboboxFilter({ id: "x", label: "Grace Hopper" }, "race")).toBe(false)
    expect(defaultComboboxFilter({ id: "x", label: "Éclair" }, "ecl")).toBe(true)
  })
})

describe("combobox with local options", () => {
  test("typing opens and filters; the input announces the active option; Enter commits", () => {
    const commits: string[] = []
    const combobox = new ComboboxController({ items: () => people, label: "People", onCommit: (o) => commits.push(o.id) })
    const { input, type, option } = render(combobox)
    input.focus()
    expect(input.getAttribute("role")).toBe("combobox")
    expect(input.getAttribute("aria-expanded")).toBe("false")
    type("a")
    expect(combobox.isOpen.peek()).toBe(true)
    expect(combobox.results.peek().map((o) => o.id)).toEqual(["ada", "alan"])
    expect(input.getAttribute("aria-activedescendant")).toBe(option("ada").id)
    press("ArrowDown")
    expect(input.getAttribute("aria-activedescendant")).toBe(option("alan").id)
    expect(document.activeElement).toBe(input)
    press("Enter")
    expect(commits).toEqual(["alan"])
    expect(input.value).toBe("Alan Turing")
    expect(combobox.isOpen.peek()).toBe(false)
    expect([...combobox.listbox.selected.peek()]).toEqual(["alan"])
  })

  test("ArrowDown opens on the first option, Escape closes then clears", () => {
    const combobox = new ComboboxController({ items: () => people })
    const { input } = render(combobox)
    input.focus()
    press("ArrowDown")
    expect(combobox.isOpen.peek()).toBe(true)
    expect(combobox.listbox.activeId.peek()).toBe("ada")
    press("Escape")
    expect(combobox.isOpen.peek()).toBe(false)
    expect(openLayerCount(document)).toBe(0)
    input.value = "gr"
    input.dispatchEvent(new Event("input"))
    press("Escape")
    press("Escape")
    expect(input.value).toBe("")
    expect(combobox.query.peek()).toBe("")
  })

  test("clicking an option commits without moving focus; outside press closes", () => {
    const combobox = new ComboboxController({ items: () => people })
    const { input, type, option } = render(combobox)
    const outside = mount(h("button", {}, "outside"))
    input.focus()
    type("g")
    pointer(option("grace"), "pointermove")
    expect(combobox.listbox.activeId.peek()).toBe("grace")
    click(option("grace"))
    expect(input.value).toBe("Grace Hopper")
    expect(document.activeElement).toBe(input)
    type("a")
    pointer(outside, "pointerdown")
    expect(combobox.isOpen.peek()).toBe(false)
  })

  test("multiple selection keeps the popup open and toggles", () => {
    const combobox = new ComboboxController({ items: () => people, selectionMode: "multiple" })
    const { input, type } = render(combobox)
    input.focus()
    type("a")
    press("Enter")
    press("ArrowDown")
    press("Enter")
    expect([...combobox.listbox.selected.peek()]).toEqual(["ada", "alan"])
    expect(combobox.isOpen.peek()).toBe(true)
    combobox.dispose()
  })
})

describe("combobox with async loading", () => {
  test("aborts stale loads, keeps old results while loading, and reports errors", async () => {
    const clock = createManualClock()
    const calls: Array<{ query: string; signal: AbortSignal; resolve: (v: ListboxOption[]) => void; reject: (e: unknown) => void }> = []
    const combobox = new ComboboxController({
      clock,
      debounce: 50,
      load: (query, signal) =>
        new Promise((resolve, reject) => {
          calls.push({ query, signal, resolve, reject })
        }),
    })
    const { input, type, renderOptions } = render(combobox)
    input.focus()
    type("a")
    clock.advance(50)
    expect(calls.map((call) => call.query)).toEqual(["a"])
    expect(combobox.status.peek()).toBe("loading")
    expect(input.getAttribute("aria-busy")).toBe("true")
    calls[0]!.resolve(people.slice(0, 2))
    await Promise.resolve()
    await Promise.resolve()
    renderOptions()
    expect(combobox.results.peek()).toHaveLength(2)
    expect(combobox.listbox.activeId.peek()).toBe("ada")

    type("al")
    clock.advance(20)
    type("ala")
    clock.advance(50)
    expect(calls.map((call) => call.query)).toEqual(["a", "ala"])
    expect(combobox.results.peek()).toHaveLength(2)
    type("alan")
    clock.advance(50)
    expect(calls[1]!.signal.aborted).toBe(true)
    calls[1]!.resolve([])
    calls[2]!.reject(new Error("offline"))
    await Promise.resolve()
    await Promise.resolve()
    expect(combobox.status.peek()).toBe("error")
    expect(combobox.results.peek()).toHaveLength(2)
    combobox.dispose()
  })
})
