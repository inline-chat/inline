// @vitest-environment happy-dom
import { afterEach, describe, expect, test } from "vitest"
import { createManualClock } from "../foundations/clock"
import { openLayerCount } from "../foundations/dismiss"
import { click, h, keydown, mount, pointer, press, setRect } from "../testing/dom"
import { MenuController, type MenuEntry } from "./controller"

const log: string[] = []

const entries = (state: { bold: boolean; size: string }): MenuEntry[] => [
  { type: "item", id: "cut", label: "Cut", onSelect: () => log.push("cut") },
  { type: "item", id: "copy", label: "Copy", onSelect: () => log.push("copy") },
  { type: "item", id: "paste", label: "Paste", disabled: true },
  { type: "separator", id: "sep1" },
  {
    type: "checkbox",
    id: "bold",
    label: "Bold",
    checked: state.bold,
    onCheckedChange: (checked) => log.push(`bold:${checked}`),
  },
  {
    type: "submenu",
    id: "size",
    label: "Size",
    items: [
      { type: "radio", id: "small", label: "Small", checked: state.size === "small", onSelect: () => log.push("small") },
      { type: "radio", id: "large", label: "Large", checked: state.size === "large", onSelect: () => log.push("large") },
      {
        type: "submenu",
        id: "more",
        label: "More",
        items: [{ type: "item", id: "huge", label: "Huge", onSelect: () => log.push("huge") }],
      },
    ],
  },
  { type: "label", id: "heading", label: "Share" },
  { type: "item", id: "copylink", label: "Copy Link", onSelect: () => log.push("copylink") },
]

/** Render the way a view does: content always mounted, submenus as siblings of their item. */
const render = (menu: MenuController, parent: HTMLElement = document.body) => {
  const trigger = mount(h("button", {}, "Edit"))
  const disposers = [menu.trigger.attach(trigger)]
  const renderLevel = (level: MenuController, into: HTMLElement) => {
    const content = h("div", { popover: "manual" })
    into.append(content)
    disposers.push(level.content.attach(content))
    for (const entry of level.entries.peek()) {
      const element = h("div", {}, entry.type === "separator" ? "" : entry.label)
      content.append(element)
      disposers.push(level.item(entry.id).attach(element))
      if (entry.type === "submenu") renderLevel(level.submenu(entry.id), content)
    }
    return content
  }
  const content = renderLevel(menu, parent)
  return { trigger, content, dispose: () => disposers.forEach((dispose) => dispose()) }
}

const item = (menu: MenuController, id: string) => document.getElementById(menu.itemDomId(id))!

const setup = (options: Partial<ConstructorParameters<typeof MenuController>[0]> = {}) => {
  const clock = createManualClock()
  const menu = new MenuController({ items: entries({ bold: false, size: "small" }), clock, ...options })
  const view = render(menu)
  return { menu, clock, ...view }
}

afterEach(() => {
  log.length = 0
  document.body.replaceChildren()
  document.documentElement.removeAttribute("dir")
})

describe("menu button", () => {
  test("wires ARIA on the trigger, content and items", () => {
    const { menu, trigger, content } = setup()
    expect(trigger.getAttribute("aria-haspopup")).toBe("menu")
    expect(trigger.getAttribute("aria-expanded")).toBe("false")
    menu.open()
    expect(trigger.getAttribute("aria-expanded")).toBe("true")
    expect(trigger.getAttribute("aria-controls")).toBe(content.id)
    expect(content.getAttribute("role")).toBe("menu")
    expect(content.getAttribute("aria-labelledby")).toBe(trigger.id)
    expect(item(menu, "copy").getAttribute("role")).toBe("menuitem")
    expect(item(menu, "paste").getAttribute("aria-disabled")).toBe("true")
    expect(item(menu, "bold").getAttribute("role")).toBe("menuitemcheckbox")
    expect(item(menu, "bold").getAttribute("aria-checked")).toBe("false")
    expect(item(menu, "sep1").getAttribute("role")).toBe("separator")
    expect(item(menu, "size").getAttribute("aria-haspopup")).toBe("menu")
    expect(item(menu, "size").getAttribute("aria-expanded")).toBe("false")
    const small = item(menu.submenu("size"), "small")
    expect(small.getAttribute("role")).toBe("menuitemradio")
    expect(small.getAttribute("aria-checked")).toBe("true")
    menu.dispose()
  })

  test("Enter, Space and ArrowDown open with the first item focused; ArrowUp with the last", () => {
    const { menu, trigger } = setup()
    for (const key of ["Enter", " ", "ArrowDown"]) {
      trigger.focus()
      keydown(trigger, key)
      expect(menu.isOpen.peek()).toBe(true)
      expect(document.activeElement).toBe(item(menu, "cut"))
      press("Escape")
      expect(menu.isOpen.peek()).toBe(false)
      expect(document.activeElement).toBe(trigger)
    }
    keydown(trigger, "ArrowUp")
    expect(document.activeElement).toBe(item(menu, "copylink"))
    menu.dispose()
  })

  test("a mouse press opens with nothing highlighted and focus on the menu; a second press closes", () => {
    const { menu, trigger, content } = setup()
    pointer(trigger, "pointerdown")
    expect(menu.isOpen.peek()).toBe(true)
    expect(menu.highlightedId.peek()).toBeNull()
    expect(document.activeElement).toBe(content)
    click(trigger)
    expect(menu.isOpen.peek()).toBe(true)
    pointer(trigger, "pointerdown")
    expect(menu.isOpen.peek()).toBe(false)
    expect(openLayerCount(document)).toBe(0)
  })

  test("a touch tap and an assistive technology click toggle through click", () => {
    const { menu, trigger } = setup()
    pointer(trigger, "pointerdown", { pointerType: "touch" })
    expect(menu.isOpen.peek()).toBe(false)
    click(trigger)
    expect(menu.isOpen.peek()).toBe(true)
    expect(menu.highlightedId.peek()).toBeNull()
    menu.close()
    click(trigger, { detail: 0 })
    expect(menu.highlightedId.peek()).toBe("cut")
    menu.dispose()
  })
})

describe("accessible names", () => {
  test("an item's name is its label; the shortcut is aria-keyshortcuts, not part of the name", () => {
    const menu = new MenuController({
      items: [
        { type: "item", id: "edit", label: "Edit", shortcut: "⌘E" },
        { type: "item", id: "delete", label: "Delete", shortcut: "⌘⌫", destructive: true },
        { type: "item", id: "redo", label: "Redo", shortcut: "⇧⌘Z", keyshortcuts: "Control+Y Shift+Meta+Z" },
        { type: "checkbox", id: "mute", label: "Mute", checked: false, shortcut: "Ctrl+Shift+M" },
        { type: "item", id: "plain", label: "Plain" },
        { type: "item", id: "odd", label: "Odd", shortcut: "Hello+World" },
      ],
    })
    render(menu)
    menu.open()
    expect(item(menu, "edit").getAttribute("aria-label")).toBe("Edit")
    expect(item(menu, "edit").getAttribute("aria-keyshortcuts")).toBe("Meta+E")
    expect(item(menu, "delete").getAttribute("aria-label")).toBe("Delete")
    expect(item(menu, "delete").getAttribute("aria-keyshortcuts")).toBe("Meta+Backspace")
    expect(item(menu, "redo").getAttribute("aria-keyshortcuts")).toBe("Control+Y Shift+Meta+Z")
    expect(item(menu, "mute").getAttribute("aria-keyshortcuts")).toBe("Control+Shift+M")
    expect(item(menu, "plain").hasAttribute("aria-keyshortcuts")).toBe(false)
    expect(item(menu, "odd").hasAttribute("aria-keyshortcuts")).toBe(false)
    expect(item(menu, "odd").getAttribute("aria-label")).toBe("Odd")
    menu.dispose()
  })
})

describe("keyboard navigation", () => {
  test("arrows move focus, skipping disabled items, separators and labels, without wrapping", () => {
    const { menu, trigger } = setup()
    keydown(trigger, "ArrowDown")
    press("ArrowDown")
    expect(document.activeElement).toBe(item(menu, "copy"))
    press("ArrowDown")
    expect(document.activeElement).toBe(item(menu, "bold"))
    press("ArrowDown")
    press("ArrowDown")
    expect(document.activeElement).toBe(item(menu, "copylink"))
    press("ArrowDown")
    expect(document.activeElement).toBe(item(menu, "copylink"))
    press("ArrowUp")
    expect(document.activeElement).toBe(item(menu, "size"))
    menu.dispose()
  })

  test("loop wraps when asked", () => {
    const { menu, trigger } = setup({ loop: true })
    keydown(trigger, "ArrowUp")
    press("ArrowDown")
    expect(document.activeElement).toBe(item(menu, "cut"))
    press("ArrowUp")
    expect(document.activeElement).toBe(item(menu, "copylink"))
    menu.dispose()
  })

  test("Home and End jump to the first and last items", () => {
    const { menu, trigger } = setup()
    keydown(trigger, "ArrowDown")
    press("End")
    expect(document.activeElement).toBe(item(menu, "copylink"))
    press("Home")
    expect(document.activeElement).toBe(item(menu, "cut"))
    menu.dispose()
  })

  test("typeahead moves to matching items and repeats cycle", () => {
    const { menu, trigger, clock } = setup()
    keydown(trigger, "ArrowDown")
    press("c")
    expect(document.activeElement).toBe(item(menu, "copy"))
    press("o")
    press("p")
    press("y")
    press(" ")
    press("l")
    expect(document.activeElement).toBe(item(menu, "copylink"))
    expect(menu.isOpen.peek()).toBe(true)
    clock.advance(600)
    press("c")
    expect(document.activeElement).toBe(item(menu, "cut"))
    press("c")
    expect(document.activeElement).toBe(item(menu, "copy"))
    menu.dispose()
  })

  test("Enter activates, closes the menu and restores focus before the handler runs", () => {
    const focusDuringSelect: Array<Element | null> = []
    const menu = new MenuController({
      items: [{ type: "item", id: "open", label: "Open", onSelect: () => focusDuringSelect.push(document.activeElement) }],
    })
    const { trigger } = render(menu)
    keydown(trigger, "Enter")
    press("Enter")
    expect(menu.isOpen.peek()).toBe(false)
    expect(focusDuringSelect).toEqual([trigger])
    expect(document.activeElement).toBe(trigger)
  })

  test("Space toggles a checkbox and onAction sees every activation", () => {
    const actions: string[] = []
    const { menu, trigger } = setup({ onAction: (entry) => actions.push(entry.id) })
    keydown(trigger, "ArrowDown")
    menu.highlight("bold")
    press(" ")
    expect(log).toEqual(["bold:true"])
    expect(actions).toEqual(["bold"])
    expect(menu.isOpen.peek()).toBe(false)
  })

  test("keepOpen items stay open after activation", () => {
    const menu = new MenuController({
      items: [{ type: "checkbox", id: "x", label: "X", checked: false, keepOpen: true, onCheckedChange: () => log.push("x") }],
    })
    const { trigger } = render(menu)
    keydown(trigger, "ArrowDown")
    press("Enter")
    expect(log).toEqual(["x"])
    expect(menu.isOpen.peek()).toBe(true)
    menu.dispose()
  })

  test("disabled items do nothing", () => {
    const { menu, trigger } = setup()
    keydown(trigger, "ArrowDown")
    menu.activate("paste")
    expect(menu.isOpen.peek()).toBe(true)
    menu.dispose()
  })

  test("Tab closes the menu and returns focus to the trigger without blocking the browser", () => {
    const { menu, trigger } = setup()
    keydown(trigger, "ArrowDown")
    const tab = press("Tab")
    expect(tab.defaultPrevented).toBe(false)
    expect(menu.isOpen.peek()).toBe(false)
    expect(document.activeElement).toBe(trigger)
  })
})

describe("submenus from the keyboard", () => {
  test("ArrowRight opens a submenu at its first item; ArrowLeft closes it back to its item", () => {
    const { menu, trigger } = setup()
    keydown(trigger, "ArrowDown")
    menu.highlight("size")
    press("ArrowRight")
    const size = menu.submenu("size")
    expect(size.isOpen.peek()).toBe(true)
    expect(item(menu, "size").getAttribute("aria-expanded")).toBe("true")
    expect(document.activeElement).toBe(item(size, "small"))
    press("ArrowDown")
    press("ArrowDown")
    press("ArrowRight")
    const more = size.submenu("more")
    expect(document.activeElement).toBe(item(more, "huge"))
    press("ArrowLeft")
    expect(more.isOpen.peek()).toBe(false)
    expect(document.activeElement).toBe(item(size, "more"))
    press("ArrowLeft")
    expect(size.isOpen.peek()).toBe(false)
    expect(document.activeElement).toBe(item(menu, "size"))
    expect(menu.isOpen.peek()).toBe(true)
    menu.dispose()
  })

  test("Enter on a submenu item opens it; activating inside closes the whole chain", () => {
    const { menu, trigger } = setup()
    keydown(trigger, "ArrowDown")
    menu.highlight("size")
    press("Enter")
    press("ArrowDown")
    press("Enter")
    expect(log).toEqual(["large"])
    expect(menu.isOpen.peek()).toBe(false)
    expect(menu.submenu("size").isOpen.peek()).toBe(false)
    expect(document.activeElement).toBe(trigger)
  })

  test("Escape closes one level at a time and restores focus each time", () => {
    const { menu, trigger } = setup()
    keydown(trigger, "ArrowDown")
    menu.highlight("size")
    press("ArrowRight")
    press("End")
    press("ArrowRight")
    expect(openLayerCount(document)).toBe(3)
    press("Escape")
    expect(menu.submenu("size").submenu("more").isOpen.peek()).toBe(false)
    expect(document.activeElement).toBe(item(menu.submenu("size"), "more"))
    press("Escape")
    expect(document.activeElement).toBe(item(menu, "size"))
    expect(menu.isOpen.peek()).toBe(true)
    press("Escape")
    expect(menu.isOpen.peek()).toBe(false)
    expect(document.activeElement).toBe(trigger)
    expect(openLayerCount(document)).toBe(0)
  })

  test("in right to left, ArrowLeft opens and ArrowRight closes", () => {
    document.documentElement.setAttribute("dir", "rtl")
    const { menu, trigger } = setup()
    keydown(trigger, "ArrowDown")
    menu.highlight("size")
    press("ArrowRight")
    expect(menu.submenu("size").isOpen.peek()).toBe(false)
    press("ArrowLeft")
    expect(document.activeElement).toBe(item(menu.submenu("size"), "small"))
    press("ArrowRight")
    expect(document.activeElement).toBe(item(menu, "size"))
    menu.dispose()
  })
})

describe("pointer", () => {
  test("hovering highlights and focuses an item; leaving the menu clears it", () => {
    const { menu, content } = setup()
    menu.open()
    pointer(item(menu, "copy"), "pointermove")
    expect(menu.highlightedId.peek()).toBe("copy")
    expect(document.activeElement).toBe(item(menu, "copy"))
    expect(item(menu, "copy").hasAttribute("data-highlighted")).toBe(true)
    pointer(content, "pointerleave")
    expect(menu.highlightedId.peek()).toBeNull()
    expect(document.activeElement).toBe(content)
    menu.dispose()
  })

  test("hovering a disabled item clears the highlight", () => {
    const { menu } = setup()
    menu.open()
    pointer(item(menu, "copy"), "pointermove")
    pointer(item(menu, "paste"), "pointermove")
    expect(menu.highlightedId.peek()).toBeNull()
    menu.dispose()
  })

  test("clicking an item activates it", () => {
    const { menu } = setup()
    menu.open()
    click(item(menu, "copy"))
    expect(log).toEqual(["copy"])
    expect(menu.isOpen.peek()).toBe(false)
  })

  test("a press elsewhere in the menu closes only the open submenu; outside closes all", () => {
    const { menu } = setup()
    const outside = mount(h("button", {}, "outside"))
    menu.open()
    menu.openSubmenu("size")
    pointer(item(menu, "cut"), "pointerdown")
    expect(menu.submenu("size").isOpen.peek()).toBe(false)
    expect(menu.isOpen.peek()).toBe(true)
    menu.openSubmenu("size")
    pointer(outside, "pointerdown")
    expect(menu.isOpen.peek()).toBe(false)
    expect(openLayerCount(document)).toBe(0)
  })
})

describe("hover intent", () => {
  const setupGeometry = () => {
    const env = setup()
    const { menu } = env
    // Items stacked at x 0..200, 24px tall; the Size submenu opens to the right.
    const ids = ["cut", "copy", "paste", "sep1", "bold", "size", "heading", "copylink"]
    ids.forEach((id, index) => setRect(item(menu, id), 0, index * 24, 200, 24))
    const sizeMenu = menu.submenu("size")
    setRect(document.getElementById(sizeMenu.id)!, 200, 115, 160, 96)
    menu.open()
    pointer(item(menu, "size"), "pointermove", { clientX: 100, clientY: 130 })
    env.clock.advance(100)
    expect(sizeMenu.isOpen.peek()).toBe(true)
    // Leave the Size item heading down-right toward the submenu.
    pointer(item(menu, "size"), "pointerleave", { clientX: 196, clientY: 143 })
    return { ...env, sizeMenu }
  }

  test("a submenu opens after the hover delay, without taking focus", () => {
    const { menu, clock } = setup()
    menu.open()
    pointer(item(menu, "size"), "pointermove")
    pointer(item(menu, "size"), "pointermove")
    clock.advance(99)
    expect(menu.submenu("size").isOpen.peek()).toBe(false)
    clock.advance(1)
    expect(menu.submenu("size").isOpen.peek()).toBe(true)
    expect(document.activeElement).toBe(item(menu, "size"))
    menu.dispose()
  })

  test("crossing a sibling inside the safe triangle keeps the submenu open", () => {
    const { menu, sizeMenu } = setupGeometry()
    pointer(item(menu, "heading"), "pointermove", { clientX: 198, clientY: 150 })
    expect(menu.highlightedId.peek()).toBe("size")
    expect(sizeMenu.isOpen.peek()).toBe(true)
    // Reaching the submenu fulfils the intent.
    pointer(document.getElementById(sizeMenu.id)!, "pointerenter", { clientX: 205, clientY: 150 })
    expect(sizeMenu.isOpen.peek()).toBe(true)
    expect(menu.highlightedId.peek()).toBe("size")
    menu.dispose()
  })

  test("resting on a sibling past the grace period moves the highlight and closes the submenu", () => {
    const { menu, sizeMenu, clock } = setupGeometry()
    pointer(item(menu, "copylink"), "pointermove", { clientX: 199, clientY: 170 })
    expect(sizeMenu.isOpen.peek()).toBe(true)
    clock.advance(300)
    expect(menu.highlightedId.peek()).toBe("copylink")
    expect(sizeMenu.isOpen.peek()).toBe(false)
    menu.dispose()
  })

  test("moving away from the submenu switches immediately", () => {
    const { menu, sizeMenu } = setupGeometry()
    pointer(item(menu, "copylink"), "pointermove", { clientX: 40, clientY: 175 })
    expect(menu.highlightedId.peek()).toBe("copylink")
    expect(sizeMenu.isOpen.peek()).toBe(false)
    menu.dispose()
  })
})

describe("focus restore", () => {
  test("restores to the element focused before opening, even when opened programmatically", () => {
    const other = mount(h("input", {}))
    other.focus()
    const { menu } = setup()
    menu.open({ highlight: "first" })
    expect(document.activeElement).toBe(item(menu, "cut"))
    menu.close()
    expect(document.activeElement).toBe(other)
  })

  test("does not pull focus back when focus already left the menu", () => {
    const { menu, trigger } = setup()
    const elsewhere = mount(h("button", {}, "elsewhere"))
    keydown(trigger, "ArrowDown")
    elsewhere.focus()
    expect(menu.isOpen.peek()).toBe(false)
    expect(document.activeElement).toBe(elsewhere)
  })
})
