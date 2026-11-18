// @vitest-environment happy-dom
import { afterEach, describe, expect, test } from "vitest"
import { openLayerCount } from "../foundations/dismiss"
import { click, h, keydown, mount, pointer, press, setRect } from "../testing/dom"
import { PopoverController } from "./controller"

const setup = (options: ConstructorParameters<typeof PopoverController>[0] = {}) => {
  const popover = new PopoverController(options)
  const trigger = mount(h("button", {}, "Info"))
  const field = h("input", { id: "field" })
  const content = mount(h("div", {}, h("p", {}, "Details"), field, h("button", { id: "done" }, "Done")))
  const outside = mount(h("button", {}, "outside"))
  popover.trigger.attach(trigger)
  popover.content.attach(content)
  return { popover, trigger, content, outside, field }
}

afterEach(() => document.body.replaceChildren())

describe("popover", () => {
  test("click toggles; ARIA reflects state; focus moves in and back", () => {
    const { popover, trigger, content, field } = setup()
    trigger.focus()
    expect(trigger.getAttribute("aria-haspopup")).toBe("dialog")
    click(trigger)
    expect(popover.isOpen.peek()).toBe(true)
    expect(trigger.getAttribute("aria-expanded")).toBe("true")
    expect(trigger.getAttribute("aria-controls")).toBe(content.id)
    expect(content.getAttribute("role")).toBe("dialog")
    expect(document.activeElement).toBe(field)
    click(trigger)
    expect(popover.isOpen.peek()).toBe(false)
    expect(document.activeElement).toBe(trigger)
  })

  test("Escape closes and restores focus", () => {
    const { popover, trigger } = setup()
    trigger.focus()
    click(trigger)
    press("Escape")
    expect(popover.isOpen.peek()).toBe(false)
    expect(document.activeElement).toBe(trigger)
    expect(openLayerCount(document)).toBe(0)
  })

  test("an outside press closes; a press inside does not; the trigger press is left to the click", () => {
    const { popover, trigger, content, outside } = setup()
    click(trigger)
    pointer(content, "pointerdown")
    expect(popover.isOpen.peek()).toBe(true)
    pointer(trigger, "pointerdown")
    expect(popover.isOpen.peek()).toBe(true)
    pointer(outside, "pointerdown")
    expect(popover.isOpen.peek()).toBe(false)
  })

  test("focus leaving closes without pulling focus back", () => {
    const { popover, trigger, outside } = setup()
    click(trigger)
    outside.focus()
    expect(popover.isOpen.peek()).toBe(false)
    expect(document.activeElement).toBe(outside)
  })

  test("initialFocus none keeps focus on the trigger; the arrow offset is published", () => {
    const { popover, trigger, content } = setup({ initialFocus: "none", arrowSize: 10, placement: "bottom" })
    setRect(trigger, 100, 100, 40, 20)
    setRect(content, 0, 0, 200, 80)
    trigger.focus()
    click(trigger)
    expect(document.activeElement).toBe(trigger)
    expect(content.getAttribute("data-side")).toBe("bottom")
    expect(content.style.getPropertyValue("--ui-arrow-x")).toBe("95px")
    keydown(trigger, "Escape")
    expect(popover.isOpen.peek()).toBe(false)
  })
})
