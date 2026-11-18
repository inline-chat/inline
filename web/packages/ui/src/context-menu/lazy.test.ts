// @vitest-environment happy-dom
import { afterEach, describe, expect, test } from "vitest"
import { openLayerCount } from "../foundations/dismiss"
import { Lazy } from "../foundations/lazy"
import { h, keydown, mount, pointer, press } from "../testing/dom"
import { ContextMenuController } from "./controller"
import type { MenuKitCore } from "./kit"
import { LazyContextMenu } from "./lazy"

const selected: string[] = []

/** A kit loader the test resolves (or rejects) when it wants: "the chunk arrives late". */
const lateKit = () => {
  let resolve: (kit: MenuKitCore) => void = () => {}
  let reject: (error: unknown) => void = () => {}
  let calls = 0
  const kit = new Lazy<MenuKitCore>(() => {
    calls++
    return new Promise<MenuKitCore>((res, rej) => {
      resolve = res
      reject = rej
    })
  })
  return {
    kit,
    calls: () => calls,
    arrive: async () => {
      resolve({ ContextMenuController })
      await kit.load()
      await Promise.resolve()
    },
    fail: async () => {
      reject(new Error("chunk failed"))
      await kit.load().catch(() => undefined)
      await Promise.resolve()
    },
  }
}

/** Render the menu as `LazyMenuContent` does: only once the controller exists. */
const renderWhenLoaded = (lazy: LazyContextMenu, region: HTMLElement) => {
  const controller = lazy.controller.peek()
  if (!controller) return null
  const content = h("div")
  region.append(content)
  controller.content.attach(content)
  for (const id of ["reply", "copy"]) {
    const element = h("div", {}, id)
    content.append(element)
    controller.item(id).attach(element)
  }
  return content
}

const setup = (options: { shouldOpen?: (event: Event) => boolean; onLoadError?: (error: unknown) => void } = {}) => {
  const loader = lateKit()
  const lazy = new LazyContextMenu({
    label: "Row actions",
    kit: loader.kit,
    items: [
      { type: "item", id: "reply", label: "Reply", onSelect: () => selected.push("reply") },
      { type: "item", id: "copy", label: "Copy", shortcut: "⌘C", onSelect: () => selected.push("copy") },
    ],
    ...options,
  })
  const region = mount(h("div", {}, h("div", { tabindex: 0, id: "row" }, "A row")))
  const row = region.querySelector<HTMLElement>("#row")!
  lazy.target.attach(region)
  return { lazy, loader, region, row }
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

describe("lazy context menu", () => {
  test("a secondary click before the chunk arrives never shows the browser's menu and opens at the pointer when it does", async () => {
    const { lazy, loader, region, row } = setup()
    row.focus()
    pointer(row, "pointerdown", { button: 2, clientX: 40, clientY: 50 })
    const event = contextmenu(row, 40, 50)
    expect(event.defaultPrevented).toBe(true)
    expect(lazy.isOpen.peek()).toBe(false)
    expect(lazy.waiting.peek()).toBe(true)
    expect(loader.calls()).toBe(1)

    await loader.arrive()
    expect(lazy.waiting.peek()).toBe(false)
    expect(lazy.isOpen.peek()).toBe(true)
    const content = renderWhenLoaded(lazy, region)!
    expect(content.style.left).toBe("40px")
    expect(content.style.top).toBe("52px")
    expect(lazy.controller.peek()?.menu.highlightedId.peek()).toBeNull()

    press("Escape")
    expect(lazy.isOpen.peek()).toBe(false)
    expect(document.activeElement).toBe(row)
    lazy.dispose()
  })

  test("the context menu key before the chunk arrives opens at the row with the first item focused; Escape returns focus", async () => {
    const { lazy, loader, region, row } = setup()
    row.focus()
    press("ContextMenu")
    const event = contextmenu(row, 0, 0)
    expect(event.defaultPrevented).toBe(true)
    await loader.arrive()
    renderWhenLoaded(lazy, region)
    expect(lazy.isOpen.peek()).toBe(true)
    expect(document.activeElement?.textContent).toBe("reply")
    press("ArrowDown")
    press("Enter")
    expect(selected).toEqual(["copy"])
    expect(document.activeElement).toBe(row)
    expect(openLayerCount(document)).toBe(0)
    lazy.dispose()
  })

  test("Shift+F10 opens from keydown, and the platform's contextmenu for the same key is not a second request", async () => {
    const { lazy, loader, region, row } = setup()
    row.focus()
    const down = keydown(row, "F10", { shiftKey: true })
    expect(down.defaultPrevented).toBe(true)
    const event = contextmenu(row, 0, 0)
    expect(event.defaultPrevented).toBe(true)
    await loader.arrive()
    renderWhenLoaded(lazy, region)
    expect(lazy.isOpen.peek()).toBe(true)
    expect(openLayerCount(document)).toBe(1)
    expect(document.activeElement?.textContent).toBe("reply")
    lazy.dispose()
  })

  test("a second request while loading replaces the first; the menu opens once, at the second point", async () => {
    const { lazy, loader, region, row } = setup()
    pointer(row, "pointerdown", { button: 2 })
    contextmenu(row, 10, 10)
    pointer(row, "pointerdown", { button: 2 })
    contextmenu(row, 100, 120)
    expect(loader.calls()).toBe(1)
    await loader.arrive()
    const content = renderWhenLoaded(lazy, region)!
    expect(content.style.left).toBe("100px")
    expect(openLayerCount(document)).toBe(1)
    lazy.dispose()
  })

  test("once loaded, a request opens synchronously", async () => {
    const { lazy, loader, region, row } = setup()
    const warmed = lazy.warm()
    await loader.arrive()
    await warmed
    renderWhenLoaded(lazy, region)
    pointer(row, "pointerdown", { button: 2 })
    contextmenu(row, 20, 30)
    expect(lazy.isOpen.peek()).toBe(true)
    lazy.dispose()
  })

  test("close() drops a request still waiting for the chunk", async () => {
    const { lazy, loader, row } = setup()
    pointer(row, "pointerdown", { button: 2 })
    contextmenu(row, 10, 10)
    lazy.close()
    expect(lazy.waiting.peek()).toBe(false)
    await loader.arrive()
    expect(lazy.isOpen.peek()).toBe(false)
    lazy.dispose()
  })

  test("shouldOpen false leaves the browser's menu and loads nothing", () => {
    const { lazy, loader, row } = setup({ shouldOpen: () => false })
    const event = contextmenu(row, 10, 10)
    expect(event.defaultPrevented).toBe(false)
    expect(loader.calls()).toBe(0)
    lazy.dispose()
  })

  test("a failed load drops the request, reports it, and the next request tries again", async () => {
    const errors: unknown[] = []
    const { lazy, loader, row } = setup({ onLoadError: (error) => errors.push(error) })
    pointer(row, "pointerdown", { button: 2 })
    contextmenu(row, 10, 10)
    await loader.fail()
    expect(errors).toHaveLength(1)
    expect(lazy.waiting.peek()).toBe(false)
    pointer(row, "pointerdown", { button: 2 })
    contextmenu(row, 10, 10)
    expect(loader.calls()).toBe(2)
    lazy.dispose()
  })

  test("openAt opens at a rectangle, as from the keyboard when asked", async () => {
    const { lazy, loader, region, row } = setup()
    row.focus()
    lazy.openAt({ x: 5, y: 6, width: 20, height: 10 }, { keyboard: true })
    await loader.arrive()
    renderWhenLoaded(lazy, region)
    expect(lazy.controller.peek()?.menu.highlightedId.peek()).toBe("reply")
    press("Escape")
    expect(document.activeElement).toBe(row)
    lazy.dispose()
  })
})
