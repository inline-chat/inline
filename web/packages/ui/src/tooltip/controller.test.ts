// @vitest-environment happy-dom
import { afterEach, describe, expect, test } from "vitest"
import { createManualClock } from "../foundations/clock"
import { h, keydown, mount, pointer, press } from "../testing/dom"
import { TooltipController, TooltipGroup } from "./controller"

const setup = () => {
  const clock = createManualClock()
  const group = new TooltipGroup({ clock, delay: 600, skipDelay: 400 })
  const make = (label: string) => {
    const tooltip = new TooltipController({ group })
    const trigger = mount(h("button", {}, label))
    const content = mount(h("div", {}, `${label} tip`))
    tooltip.trigger.attach(trigger)
    tooltip.content.attach(content)
    return { tooltip, trigger, content }
  }
  return { clock, group, a: make("Bold"), b: make("Italic") }
}

afterEach(() => document.body.replaceChildren())

describe("tooltip", () => {
  test("hover opens after the delay and leaving closes", () => {
    const { clock, a } = setup()
    expect(a.trigger.getAttribute("aria-describedby")).toBe(a.content.id)
    expect(a.content.getAttribute("role")).toBe("tooltip")
    pointer(a.trigger, "pointerenter")
    clock.advance(599)
    expect(a.tooltip.isOpen.peek()).toBe(false)
    clock.advance(1)
    expect(a.tooltip.isOpen.peek()).toBe(true)
    pointer(a.trigger, "pointerleave")
    expect(a.tooltip.isOpen.peek()).toBe(false)
  })

  test("a neighbor in the group opens instantly while one is showing or just closed, and only one shows", () => {
    const { clock, a, b } = setup()
    pointer(a.trigger, "pointerenter")
    clock.advance(600)
    pointer(b.trigger, "pointerenter")
    expect(b.tooltip.isOpen.peek()).toBe(true)
    expect(a.tooltip.isOpen.peek()).toBe(false)
    pointer(b.trigger, "pointerleave")
    clock.advance(300)
    pointer(a.trigger, "pointerenter")
    expect(a.tooltip.isOpen.peek()).toBe(true)
    pointer(a.trigger, "pointerleave")
    clock.advance(500)
    pointer(b.trigger, "pointerenter")
    expect(b.tooltip.isOpen.peek()).toBe(false)
  })

  test("keyboard focus opens at once; pointer and touch focus do not", () => {
    const { a, b } = setup()
    keydown(document.body, "Tab")
    a.trigger.focus()
    expect(a.tooltip.isOpen.peek()).toBe(true)
    b.trigger.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, pointerType: "touch" }))
    b.trigger.focus()
    expect(a.tooltip.isOpen.peek()).toBe(false)
    expect(b.tooltip.isOpen.peek()).toBe(false)
    pointer(b.trigger, "pointerdown")
    a.trigger.focus()
    expect(a.tooltip.isOpen.peek()).toBe(false)
  })

  test("touch hover never opens; a press closes; Escape closes", () => {
    const { clock, a } = setup()
    pointer(a.trigger, "pointerenter", { pointerType: "touch" })
    clock.advance(1000)
    expect(a.tooltip.isOpen.peek()).toBe(false)
    pointer(a.trigger, "pointerenter")
    clock.advance(600)
    pointer(a.trigger, "pointerdown")
    expect(a.tooltip.isOpen.peek()).toBe(false)
    a.tooltip.open()
    press("Escape")
    expect(a.tooltip.isOpen.peek()).toBe(false)
  })
})
