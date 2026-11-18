import { describe, expect, it } from "vitest"
import { DropTarget } from "./drop-target"

/** Node's own `EventTarget` stands in for the pane, a child and the window: no DOM needed. */
const view = new EventTarget()
const node = (parent?: EventTarget) => {
  const target = new EventTarget() as EventTarget & { ownerDocument: { defaultView: EventTarget } }
  target.ownerDocument = { defaultView: view }
  if (parent) {
    // Bubble to the parent, as the DOM does.
    const dispatch = target.dispatchEvent.bind(target)
    target.dispatchEvent = (event: Event) => {
      const result = dispatch(event)
      if (event.bubbles) parent.dispatchEvent(event)
      return result
    }
  }
  return target
}

const drag = (type: string, target: EventTarget, options: { files?: File[]; types?: string[]; prevented?: boolean } = {}) => {
  const event = new Event(type, { bubbles: true, cancelable: true })
  const files = options.files ?? []
  Object.defineProperty(event, "dataTransfer", {
    value: { types: options.types ?? (files.length > 0 ? ["Files"] : ["text/plain"]), files, dropEffect: "none" },
  })
  if (options.prevented) event.preventDefault()
  target.dispatchEvent(event)
  return event
}

const setup = (enabled = () => true) => {
  const pane = node()
  const child = node(pane)
  const dropped: File[][] = []
  const target = new DropTarget({ onFiles: (files) => dropped.push([...files]), enabled })
  const detach = target.attach(pane as unknown as HTMLElement)
  return { pane, child, target, dropped, detach }
}

describe("DropTarget", () => {
  it("shows while files are dragged over the pane, through crossings of its children, and takes the drop", () => {
    const { pane, child, target, dropped } = setup()
    const files = [new File(["x"], "a.png", { type: "image/png" })]
    expect(drag("dragenter", pane, { files }).defaultPrevented).toBe(true)
    drag("dragenter", child, { files })
    drag("dragleave", pane, { files })
    expect(target.active.peek()).toBe(true)
    expect(drag("dragover", child, { files }).defaultPrevented).toBe(true)
    drag("drop", child, { files })
    expect(target.active.peek()).toBe(false)
    expect(dropped.map((list) => list.map((file) => file.name))).toEqual([["a.png"]])
  })

  it("leaves text drags and drops the composer already took alone", () => {
    const { pane, child, target, dropped } = setup()
    expect(drag("dragenter", pane, { types: ["text/plain"] }).defaultPrevented).toBe(false)
    expect(target.active.peek()).toBe(false)
    const files = [new File(["x"], "a.png", { type: "image/png" })]
    drag("dragenter", pane, { files })
    drag("drop", child, { files, prevented: true })
    expect(target.active.peek()).toBe(false)
    expect(dropped).toEqual([])
  })

  it("does nothing while disabled, and resets when the drag leaves or is cancelled", () => {
    let enabled = false
    const { pane, target, dropped, detach } = setup(() => enabled)
    const files = [new File(["x"], "a.png", { type: "image/png" })]
    drag("dragenter", pane, { files })
    drag("drop", pane, { files })
    expect(target.active.peek()).toBe(false)
    expect(dropped).toEqual([])
    enabled = true
    drag("dragenter", pane, { files })
    drag("dragleave", pane, { files })
    expect(target.active.peek()).toBe(false)
    drag("dragenter", pane, { files })
    view.dispatchEvent(new Event("dragend"))
    expect(target.active.peek()).toBe(false)
    drag("dragenter", pane, { files })
    detach()
    expect(target.active.peek()).toBe(false)
  })
})
