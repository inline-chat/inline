// @vitest-environment happy-dom
import { afterEach, describe, expect, test } from "vitest"
import { createManualClock } from "../foundations/clock"
import { h, mount, pointer, setRect } from "../testing/dom"
import { ToastQueue, toastPlacement } from "./controller"

const titles = (queue: ToastQueue) => queue.visible.peek().map((toast) => toast.title)

afterEach(() => document.body.replaceChildren())

describe("toast queue", () => {
  test("shows up to max, queues the rest, and times out visible toasts only", () => {
    const clock = createManualClock()
    const queue = new ToastQueue({ clock, max: 2, duration: 1000 })
    queue.show({ title: "one" })
    clock.advance(500)
    queue.show({ title: "two" })
    queue.show({ title: "three" })
    expect(titles(queue)).toEqual(["one", "two"])
    clock.advance(500)
    expect(titles(queue)).toEqual(["two", "three"])
    clock.advance(500)
    expect(titles(queue)).toEqual(["three"])
    // "three" became visible at 1000ms, so it times out at 2000ms.
    clock.advance(499)
    expect(titles(queue)).toEqual(["three"])
    clock.advance(1)
    expect(titles(queue)).toEqual([])
  })

  test("reusing an id replaces in place and restarts its timer; Infinity is sticky", () => {
    const clock = createManualClock()
    const queue = new ToastQueue({ clock, duration: 1000 })
    const id = queue.show({ title: "Uploading", duration: Infinity })
    clock.advance(10_000)
    expect(titles(queue)).toEqual(["Uploading"])
    queue.show({ id, title: "Uploaded", tone: "success" })
    expect(queue.visible.peek()[0]).toMatchObject({ id, title: "Uploaded", tone: "success" })
    clock.advance(1000)
    expect(titles(queue)).toEqual([])
  })

  test("hovering or focusing the region pauses with the remaining time kept", () => {
    const clock = createManualClock()
    const queue = new ToastQueue({ clock, duration: 1000 })
    const region = mount(h("section"))
    queue.region.attach(region)
    expect(region.getAttribute("role")).toBe("region")
    expect(region.getAttribute("aria-label")).toBe("Notifications")
    queue.show({ title: "Saved" })
    clock.advance(600)
    pointer(region, "pointerenter")
    clock.advance(5000)
    expect(titles(queue)).toEqual(["Saved"])
    pointer(region, "pointerleave")
    clock.advance(399)
    expect(titles(queue)).toEqual(["Saved"])
    clock.advance(1)
    expect(titles(queue)).toEqual([])

    queue.show({ title: "Again" })
    const button = h("button", {}, "Undo")
    region.append(button)
    button.focus()
    clock.advance(5000)
    expect(titles(queue)).toEqual(["Again"])
    button.blur()
    clock.advance(1000)
    expect(titles(queue)).toEqual([])
  })

  test("dismiss removes at once and promotes the next", () => {
    const clock = createManualClock()
    const queue = new ToastQueue({ clock, max: 1 })
    const first = queue.show({ title: "a" })
    queue.show({ title: "b" })
    queue.dismiss(first)
    expect(titles(queue)).toEqual(["b"])
    queue.clear()
    expect(queue.toasts.peek()).toEqual([])
    expect(clock.pending()).toBe(0)
  })
})

describe("toast placement", () => {
  const viewport = { width: 1200, height: 800 }

  test("without a container: the window's inline-end, block-end corner at the offset", () => {
    expect(toastPlacement(null, viewport, "ltr")).toEqual({ insetInlineEnd: 16, insetBlockEnd: 16 })
    expect(toastPlacement(null, viewport, "rtl", { inline: 8, block: 24 })).toEqual({ insetInlineEnd: 8, insetBlockEnd: 24 })
  })

  test("a container's inline-end, block-end corner, left to right and right to left", () => {
    // A message list from x 300 to 1000, y 46 to 700 (the composer below it).
    const list = { x: 300, y: 46, width: 700, height: 654 }
    expect(toastPlacement(list, viewport, "ltr", { inline: 12, block: 12 })).toEqual({
      insetInlineEnd: 212,
      insetBlockEnd: 112,
      maxInlineSize: 676,
    })
    expect(toastPlacement(list, viewport, "rtl", { inline: 12, block: 12 })).toEqual({
      insetInlineEnd: 312,
      insetBlockEnd: 112,
      maxInlineSize: 676,
    })
  })

  test("the region follows the newest container and falls back when it detaches", () => {
    const queue = new ToastQueue({ offset: { inline: 10, block: 10 } })
    const region = mount(h("section"))
    const pane = mount(h("div"))
    setRect(pane, 200, 0, 600, 500)
    queue.region.attach(region)
    const detach = queue.container.attach(pane)
    queue.show({ title: "Saved", description: "A long description that wraps." })
    const width = document.documentElement.clientWidth || window.innerWidth
    const height = document.documentElement.clientHeight || window.innerHeight
    expect(region.style.getPropertyValue("--ui-toast-inset-inline-end")).toBe(`${width - 800 + 10}px`)
    expect(region.style.getPropertyValue("--ui-toast-inset-block-end")).toBe(`${height - 500 + 10}px`)
    expect(region.style.getPropertyValue("--ui-toast-max-inline-size")).toBe("580px")
    detach()
    expect(region.style.getPropertyValue("--ui-toast-inset-inline-end")).toBe("10px")
    expect(region.style.getPropertyValue("--ui-toast-max-inline-size")).toBe("")
    queue.dispose()
  })
})
