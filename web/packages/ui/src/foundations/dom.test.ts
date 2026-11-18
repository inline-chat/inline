// @vitest-environment happy-dom
import { afterEach, describe, expect, test } from "vitest"
import { h, keydown, mount, setRect } from "../testing/dom"
import { type DismissReason, openLayerCount, pushDismissLayer } from "./dismiss"
import { activateFocusScope, getTabbables, RovingTabIndex } from "./focus"
import { placeLayer, showLayer } from "./layer"
import { createModalityTracker } from "./modality"

const press = (target: Element) =>
  target.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, composed: true, pointerType: "mouse" }))

afterEach(() => {
  document.body.replaceChildren()
})

describe("dismiss stack", () => {
  const setup = () => {
    const outside = mount(h("button", { id: "outside" }, "outside"))
    const trigger = mount(h("button", { id: "trigger" }, "trigger"))
    const menu = mount(h("div", { id: "menu" }, h("button", { id: "item" }, "item")))
    const submenu = mount(h("div", { id: "submenu" }, h("button", { id: "subitem" }, "sub")))
    const log: string[] = []
    const root = pushDismissLayer(document, {
      elements: () => [menu],
      ignore: () => [trigger],
      focusOutside: true,
      onDismiss: (reason: DismissReason) => {
        log.push(`root:${reason}`)
        root.dispose()
      },
    })
    const child = pushDismissLayer(document, {
      elements: () => [submenu],
      parent: root,
      onDismiss: (reason: DismissReason) => {
        log.push(`child:${reason}`)
        child.dispose()
      },
    })
    return { outside, trigger, menu, submenu, log, root, child }
  }

  test("a press inside the parent closes only the submenu", () => {
    const { menu, log } = setup()
    press(menu.querySelector("#item")!)
    expect(log).toEqual(["child:outside-press"])
    expect(openLayerCount(document)).toBe(1)
  })

  test("a press inside the submenu closes nothing", () => {
    const { submenu, log, root, child } = setup()
    press(submenu.querySelector("#subitem")!)
    expect(log).toEqual([])
    child.dispose()
    root.dispose()
  })

  test("a press outside both closes both, top first", () => {
    const { outside, log } = setup()
    press(outside)
    expect(log).toEqual(["child:outside-press", "root:outside-press"])
    expect(openLayerCount(document)).toBe(0)
  })

  test("a press on the trigger is left to the trigger", () => {
    const { trigger, log, root, child } = setup()
    press(trigger)
    expect(log).toEqual([])
    child.dispose()
    root.dispose()
  })

  test("Escape closes one level per press", () => {
    const { outside, log } = setup()
    const first = keydown(outside, "Escape")
    expect(first.defaultPrevented).toBe(true)
    expect(log).toEqual(["child:escape"])
    keydown(outside, "Escape")
    expect(log).toEqual(["child:escape", "root:escape"])
    const third = keydown(outside, "Escape")
    expect(third.defaultPrevented).toBe(false)
  })

  test("focus moving into the submenu stays inside the root's tree; focus leaving closes the root", () => {
    const { outside, submenu, log, child } = setup()
    ;(submenu.querySelector("#subitem") as HTMLElement).focus()
    expect(log).toEqual([])
    outside.focus()
    expect(log).toEqual(["root:focus-outside"])
    child.dispose()
  })

  test("a layer that refuses outside presses shields the layers below it", () => {
    const outside = mount(h("button", {}, "outside"))
    const dialog = mount(h("div", {}, h("button", {}, "in dialog")))
    const log: string[] = []
    const below = pushDismissLayer(document, { elements: () => [], onDismiss: () => log.push("below") })
    const modal = pushDismissLayer(document, {
      elements: () => [dialog],
      outsidePress: false,
      onDismiss: () => log.push("modal"),
    })
    press(outside)
    expect(log).toEqual([])
    modal.dispose()
    below.dispose()
    expect(openLayerCount(document)).toBe(0)
  })
})

describe("focus scope", () => {
  test("tabbables skip disabled, hidden, inert and negative tabindex, and order positive tabindex first", () => {
    const root = mount(
      h(
        "div",
        {},
        h("button", { id: "a" }, "a"),
        h("button", { id: "b", disabled: true }, "b"),
        h("div", { hidden: true }, h("button", { id: "c" }, "c")),
        h("div", { inert: true }, h("button", { id: "d" }, "d")),
        h("span", { id: "e", tabindex: -1 }, "e"),
        h("a", { id: "f", href: "#" }, "f"),
        h("span", { id: "g", tabindex: 2 }, "g"),
        h("input", { id: "r1", type: "radio", name: "r" }),
        h("input", { id: "r2", type: "radio", name: "r", checked: true }),
      ),
    )
    expect(getTabbables(root).map((element) => element.id)).toEqual(["g", "a", "f", "r2"])
  })

  test("traps Tab and Shift+Tab at the edges, and restores focus on deactivate", () => {
    const opener = mount(h("button", { id: "opener" }, "open"))
    opener.focus()
    const dialog = mount(h("div", {}, h("button", { id: "first" }, "1"), h("button", { id: "last" }, "2")))
    const scope = activateFocusScope(dialog, { trap: true })
    expect(document.activeElement?.id).toBe("first")
    const shiftTab = keydown(document.activeElement!, "Tab", { shiftKey: true })
    expect(shiftTab.defaultPrevented).toBe(true)
    expect(document.activeElement?.id).toBe("last")
    keydown(document.activeElement!, "Tab")
    expect(document.activeElement?.id).toBe("first")
    scope.deactivate()
    expect(document.activeElement).toBe(opener)
  })

  test("pulls focus back when it escapes a trap", () => {
    const outside = mount(h("button", {}, "outside"))
    const dialog = mount(h("div", {}, h("button", { id: "inside" }, "in")))
    const scope = activateFocusScope(dialog, { trap: true })
    outside.focus()
    expect(document.activeElement?.id).toBe("inside")
    scope.deactivate({ restore: false })
  })

  test("leaves focus alone inside our own layers opened above the trap", () => {
    const dialog = mount(h("div", {}, h("button", { id: "inside" }, "in")))
    const menu = mount(h("div", { "data-ui-layer": true }, h("button", { id: "menuitem" }, "item")))
    const scope = activateFocusScope(dialog, { trap: true })
    ;(menu.firstElementChild as HTMLElement).focus()
    expect(document.activeElement?.id).toBe("menuitem")
    scope.deactivate({ restore: false })
  })

  test("honors autofocus", () => {
    const dialog = mount(h("div", {}, h("button", {}, "1"), h("input", { id: "auto", autofocus: true })))
    const scope = activateFocusScope(dialog)
    expect(document.activeElement?.id).toBe("auto")
    scope.deactivate({ restore: false })
  })

  test("does not steal focus back on deactivate when the user moved elsewhere", () => {
    const opener = mount(h("button", {}, "open"))
    const elsewhere = mount(h("button", {}, "elsewhere"))
    opener.focus()
    const panel = mount(h("div", {}, h("button", {}, "in")))
    const scope = activateFocusScope(panel)
    elsewhere.focus()
    scope.deactivate()
    expect(document.activeElement).toBe(elsewhere)
  })

  test("restores focus when the focused element was removed", () => {
    const opener = mount(h("button", {}, "open"))
    opener.focus()
    const panel = mount(h("div", {}, h("button", {}, "in")))
    const scope = activateFocusScope(panel)
    panel.remove()
    scope.deactivate()
    expect(document.activeElement).toBe(opener)
  })
})

describe("roving tab index", () => {
  test("one item is tabbable and setCurrent moves focus", () => {
    const a = mount(h("button", { id: "a" }, "a"))
    const b = mount(h("button", { id: "b" }, "b"))
    const roving = new RovingTabIndex("a")
    roving.register("a", a)
    roving.register("b", b)
    expect([a.tabIndex, b.tabIndex]).toEqual([0, -1])
    roving.setCurrent("b", true)
    expect([a.tabIndex, b.tabIndex]).toEqual([-1, 0])
    expect(document.activeElement).toBe(b)
  })
})

describe("modality", () => {
  test("tracks keyboard, pointer and touch, ignoring command chords", () => {
    const tracker = createModalityTracker(document)
    expect(tracker.modality.peek()).toBe("pointer")
    keydown(document.body, "a")
    expect(tracker.isKeyboard()).toBe(true)
    document.body.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, pointerType: "touch" }))
    expect(tracker.modality.peek()).toBe("touch")
    keydown(document.body, "c", { metaKey: true })
    expect(tracker.modality.peek()).toBe("touch")
    document.body.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, pointerType: "mouse" }))
    expect(tracker.modality.peek()).toBe("pointer")
    tracker.dispose()
  })
})

describe("layer placement", () => {
  test("writes fixed coordinates, side and available size", () => {
    const anchor = mount(h("button", {}, "anchor"))
    const layer = mount(h("div", {}, "layer"))
    setRect(anchor, 10, 20, 50, 20)
    setRect(layer, 0, 0, 100, 60)
    showLayer(layer)
    expect(layer.getAttribute("popover")).toBe("manual")
    expect(layer.hasAttribute("data-ui-layer")).toBe(true)
    const result = placeLayer(layer, {
      anchor,
      placement: "bottom-start",
      offset: 4,
      boundary: () => ({ x: 0, y: 0, width: 400, height: 300 }),
    })
    expect(result?.side).toBe("bottom")
    expect(layer.style.left).toBe("10px")
    expect(layer.style.top).toBe("44px")
    expect(layer.getAttribute("data-side")).toBe("bottom")
    expect(layer.style.getPropertyValue("--ui-available-height")).toBe("256px")
  })

  test("reads the writing direction from the closest dir attribute", () => {
    const anchor = h("button", {}, "anchor")
    const layer = h("div", {}, "layer")
    mount(h("div", { dir: "rtl" }, anchor, layer))
    setRect(anchor, 200, 20, 50, 20)
    setRect(layer, 0, 0, 100, 60)
    placeLayer(layer, { anchor, placement: "bottom-start", boundary: () => ({ x: 0, y: 0, width: 400, height: 300 }) })
    expect(layer.style.left).toBe("150px")
  })
})
