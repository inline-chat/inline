// @vitest-environment happy-dom
import { afterEach, describe, expect, test } from "vitest"
import { click, h, mount, press } from "../testing/dom"
import { TabsController } from "./controller"

const render = (tabs: TabsController, ids: string[], dir?: "rtl") => {
  const list = mount(h("div", dir ? { dir } : {}))
  tabs.list.attach(list)
  const elements: Record<string, HTMLElement> = {}
  for (const id of ids) {
    const tab = h("button", {}, id)
    list.append(tab)
    tabs.tab(id).attach(tab)
    elements[id] = tab
    const panel = mount(h("div", {}, `${id} panel`))
    tabs.panel(id).attach(panel)
  }
  return { list, elements }
}

const specs = () => [{ id: "general" }, { id: "privacy", disabled: true }, { id: "advanced" }, { id: "about" }]

afterEach(() => document.body.replaceChildren())

describe("tabs", () => {
  test("ARIA and roving tab index", () => {
    const tabs = new TabsController({ tabs: specs, label: "Settings" })
    const { list, elements } = render(tabs, ["general", "privacy", "advanced", "about"])
    expect(list.getAttribute("role")).toBe("tablist")
    expect(elements.general!.getAttribute("aria-selected")).toBe("true")
    expect(elements.general!.tabIndex).toBe(0)
    expect(elements.advanced!.tabIndex).toBe(-1)
    expect(elements.general!.getAttribute("aria-controls")).toBe(tabs.panelDomId("general"))
    const panel = document.getElementById(tabs.panelDomId("advanced"))!
    expect(panel.getAttribute("aria-labelledby")).toBe(elements.advanced!.id)
    expect(panel.hidden).toBe(true)
  })

  test("automatic activation: arrows select, skipping disabled, wrapping; Home and End", () => {
    const changes: string[] = []
    const tabs = new TabsController({ tabs: specs, onChange: (id) => changes.push(id) })
    const { elements } = render(tabs, ["general", "privacy", "advanced", "about"])
    elements.general!.focus()
    press("ArrowRight")
    expect(document.activeElement).toBe(elements.advanced)
    expect(tabs.selectedId.peek()).toBe("advanced")
    press("ArrowRight")
    press("ArrowRight")
    expect(tabs.selectedId.peek()).toBe("general")
    press("End")
    expect(tabs.selectedId.peek()).toBe("about")
    press("Home")
    expect(changes).toEqual(["advanced", "about", "general", "about", "general"])
    expect(document.getElementById(tabs.panelDomId("general"))!.hidden).toBe(false)
  })

  test("manual activation moves focus only until Enter or Space", () => {
    const tabs = new TabsController({ tabs: specs, activation: "manual" })
    const { elements } = render(tabs, ["general", "privacy", "advanced", "about"])
    elements.general!.focus()
    press("ArrowRight")
    expect(document.activeElement).toBe(elements.advanced)
    expect(elements.advanced!.tabIndex).toBe(0)
    expect(tabs.selectedId.peek()).toBe("general")
    press(" ")
    expect(tabs.selectedId.peek()).toBe("advanced")
  })

  test("right to left reverses the arrows; clicks select", () => {
    const tabs = new TabsController({ tabs: specs })
    const { elements } = render(tabs, ["general", "privacy", "advanced", "about"], "rtl")
    elements.general!.focus()
    press("ArrowLeft")
    expect(tabs.selectedId.peek()).toBe("advanced")
    click(elements.about!)
    expect(tabs.selectedId.peek()).toBe("about")
    click(elements.privacy!)
    expect(tabs.selectedId.peek()).toBe("about")
  })

  test("vertical tabs use up and down", () => {
    const tabs = new TabsController({ tabs: specs, orientation: "vertical" })
    const { list, elements } = render(tabs, ["general", "privacy", "advanced", "about"])
    expect(list.getAttribute("aria-orientation")).toBe("vertical")
    elements.general!.focus()
    press("ArrowRight")
    expect(tabs.selectedId.peek()).toBe("general")
    press("ArrowDown")
    expect(tabs.selectedId.peek()).toBe("advanced")
  })
})
