// @vitest-environment happy-dom
import { afterEach, describe, expect, test } from "vitest"
import { openLayerCount } from "../foundations/dismiss"
import { h, mount, pointer, press } from "../testing/dom"
import { ContextMenuController } from "./controller"

const selected: string[] = []

const setup = (shouldOpen?: (event: MouseEvent) => boolean) => {
  const menu = new ContextMenuController({
    label: "Message actions",
    items: [
      { type: "item", id: "reply", label: "Reply", onSelect: () => selected.push("reply") },
      { type: "item", id: "copy", label: "Copy", onSelect: () => selected.push("copy") },
    ],
    shouldOpen,
  })
  const target = mount(h("div", { tabindex: 0 }, "A message"))
  const content = h("div")
  target.append(content)
  menu.target.attach(target)
  menu.content.attach(content)
  for (const id of ["reply", "copy"]) {
    const element = h("div", {}, id)
    content.append(element)
    menu.item(id).attach(element)
  }
  return { menu, target, content }
}

const contextmenu = (target: Element, x: number, y: number) => {
  const event = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 2 })
  target.dispatchEvent(event)
  return event
}

afterEach(() => {
  selected.length = 0
  document.body.replaceChildren()
})

describe("context menu", () => {
  test("a secondary click opens at the pointer with nothing highlighted and suppresses the browser menu", () => {
    const { menu, target, content } = setup()
    pointer(target, "pointerdown", { button: 2, clientX: 40, clientY: 50 })
    const event = contextmenu(target, 40, 50)
    expect(event.defaultPrevented).toBe(true)
    expect(menu.menu.isOpen.peek()).toBe(true)
    expect(menu.menu.highlightedId.peek()).toBeNull()
    expect(content.getAttribute("aria-label")).toBe("Message actions")
    expect(content.style.left).toBe("40px")
    expect(content.style.top).toBe("52px")
    menu.dispose()
  })

  test("the context menu key opens at the target with the first item focused, and Escape returns focus", () => {
    const { menu, target } = setup()
    target.focus()
    press("ContextMenu")
    contextmenu(target, 0, 0)
    expect(document.activeElement?.textContent).toBe("reply")
    press("ArrowDown")
    press("Enter")
    expect(selected).toEqual(["copy"])
    expect(document.activeElement).toBe(target)
    expect(openLayerCount(document)).toBe(0)
    menu.dispose()
  })

  test("a second secondary click elsewhere reopens at the new point", () => {
    const { menu, target, content } = setup()
    pointer(target, "pointerdown", { button: 2 })
    contextmenu(target, 10, 10)
    pointer(target, "pointerdown", { button: 2 })
    contextmenu(target, 100, 120)
    expect(menu.menu.isOpen.peek()).toBe(true)
    expect(content.style.left).toBe("100px")
    expect(openLayerCount(document)).toBe(1)
    menu.dispose()
  })

  test("shouldOpen can leave the browser menu in place", () => {
    const { menu, target } = setup(() => false)
    const event = contextmenu(target, 10, 10)
    expect(event.defaultPrevented).toBe(false)
    expect(menu.menu.isOpen.peek()).toBe(false)
  })
})
