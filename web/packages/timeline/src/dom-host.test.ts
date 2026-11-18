// @vitest-environment happy-dom
/**
 * What happy-dom can honestly check: event classification, mutation
 * reporting, the scrollend fallback, animation through injected frames, and
 * the geometry queries given element rectangles. happy-dom has no layout
 * (every rectangle is zero, its ResizeObserver never fires), so rectangles are
 * stubbed here and real layout, resize observation, clamping and drift are
 * left to browser tests (see the README).
 */
import { afterEach, describe, expect, it } from "vitest"
import { createDomHost, DEFAULT_KEY_ATTRIBUTE, type DomHost } from "./dom-host"
import type { HostEvent } from "./host"
import { createFakeHost } from "./testing/fake-host"

const hosts: DomHost[] = []
afterEach(() => {
  for (const host of hosts.splice(0)) host.dispose()
  document.body.replaceChildren()
})

const stubRect = (element: Element, top: number, height: number) => {
  element.getBoundingClientRect = () =>
    ({ top, bottom: top + height, height, left: 0, right: 100, width: 100, x: 0, y: top, toJSON: () => ({}) }) as DOMRect
}

const row = (key: string) => {
  const element = document.createElement("div")
  element.setAttribute(DEFAULT_KEY_ATTRIBUTE, key)
  return element
}

const setup = (keys: string[] = []) => {
  const time = createFakeHost()
  const container = document.createElement("div")
  for (const key of keys) container.append(row(key))
  document.body.append(container)
  const host = createDomHost(container, { clock: time.clock, frames: time.frames })
  hosts.push(host)
  const events: HostEvent[] = []
  host.subscribe((event) => events.push(event))
  return { time, container, host, events }
}

const microtask = () => new Promise<void>((resolve) => queueMicrotask(resolve))

describe("dom host: setup and rows", () => {
  it("turns off the browser's scroll anchoring on the container", () => {
    const { container } = setup()
    expect(container.style.getPropertyValue("overflow-anchor")).toBe("none")
  })

  it("lists the rendered rows in order, skipping children without a key", () => {
    const { container, host } = setup(["a", "b"])
    container.append(document.createElement("span"))
    expect(host.rowKeys()).toEqual(["a", "b"])
  })

  it("reports a commit in the microtask after it, measuring only new rows", async () => {
    const { container, host, events } = setup(["b", "c"])
    const a = row("a")
    stubRect(a, 0, 42)
    container.prepend(a)
    container.lastElementChild!.remove()
    expect(events).toEqual([])
    await microtask()
    expect(events).toEqual([{ kind: "rows", keys: ["a", "b"], measured: [{ key: "a", height: 42 }] }])
    expect(host.rowKeys()).toEqual(["a", "b"])
  })

  it("reads rows from a separate content element when given one", async () => {
    const time = createFakeHost()
    const container = document.createElement("div")
    const content = document.createElement("div")
    container.append(content)
    document.body.append(container)
    const host = createDomHost(container, { content, clock: time.clock, frames: time.frames })
    hosts.push(host)
    const events: HostEvent[] = []
    host.subscribe((event) => events.push(event))
    content.append(row("x"))
    await microtask()
    expect(events.map((event) => event.kind)).toEqual(["rows"])
    expect(host.rowKeys()).toEqual(["x"])
  })
})

describe("dom host: geometry", () => {
  const laidOut = (count: number, height: number) => {
    const keys = Array.from({ length: count }, (_, i) => `m:${i}`)
    const setupResult = setup(keys)
    const { container } = setupResult
    Object.defineProperty(container, "clientHeight", { value: 300, configurable: true })
    Object.defineProperty(container, "clientTop", { value: 0, configurable: true })
    stubRect(container, 100, 300)
    let scrollTop = 0
    const place = () => {
      Array.from(container.children).forEach((child, i) => stubRect(child, 100 + i * height - scrollTop, height))
    }
    place()
    return {
      ...setupResult,
      scrollTo: (value: number) => {
        scrollTop = value
        place()
      },
    }
  }

  it("gives row rectangles relative to the viewport's top edge", () => {
    const { host, scrollTo } = laidOut(100, 40)
    expect(host.rowRect("m:3")).toEqual({ top: 120, bottom: 160 })
    scrollTo(200)
    expect(host.rowRect("m:3")).toEqual({ top: -80, bottom: -40 })
    expect(host.rowRect("nope")).toBeUndefined()
  })

  it("finds the rows intersecting the viewport", () => {
    const { host, scrollTo } = laidOut(1000, 40)
    expect(host.visibleKeys()).toEqual(Array.from({ length: 8 }, (_, i) => `m:${i}`))
    scrollTo(10_010)
    // Rows 250 (cut at the top) to 257 (cut at the bottom).
    expect(host.visibleKeys()).toEqual(Array.from({ length: 8 }, (_, i) => `m:${250 + i}`))
  })

  it("reads and writes the scroll offset and the viewport", () => {
    const { container, host } = laidOut(10, 40)
    Object.defineProperty(container, "scrollHeight", { value: 400, configurable: true })
    host.setScrollOffset(64.5)
    expect(container.scrollTop).toBe(64.5)
    expect(host.scrollOffset()).toBe(64.5)
    expect(host.viewportHeight()).toBe(300)
    expect(host.contentHeight()).toBe(400)
  })
})

describe("dom host: user input", () => {
  const wheel = (deltaY: number, ctrlKey = false) => {
    const event = new WheelEvent("wheel", { deltaY, ctrlKey })
    // happy-dom drops `ctrlKey` from the init dictionary.
    if (event.ctrlKey !== ctrlKey) Object.defineProperty(event, "ctrlKey", { value: ctrlKey })
    return event
  }

  it("classifies wheel direction and ignores pinch zoom and sideways wheels", () => {
    const { container, events } = setup()
    container.dispatchEvent(wheel(-3))
    container.dispatchEvent(wheel(5))
    container.dispatchEvent(wheel(-3, true))
    container.dispatchEvent(wheel(0))
    expect(events).toEqual([
      { kind: "input", source: "wheel", direction: "up" },
      { kind: "input", source: "wheel", direction: "down" },
    ])
  })

  it("classifies scrolling keys, and ignores keys typed into editable elements", () => {
    const { container, events } = setup()
    const input = document.createElement("input")
    const editable = document.createElement("div")
    editable.setAttribute("contenteditable", "true")
    container.append(input, editable)
    const key = (target: Element, init: KeyboardEventInit) =>
      target.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, ...init }))
    key(container, { key: "PageUp" })
    key(container, { key: "Home" })
    key(container, { key: "ArrowDown" })
    key(container, { key: "End" })
    key(container, { key: " ", shiftKey: true })
    key(container, { key: " " })
    key(container, { key: "a" })
    key(input, { key: "ArrowUp" })
    key(editable, { key: "PageDown" })
    expect(events.map((event) => (event.kind === "input" ? event.direction : event.kind))).toEqual([
      "up",
      "up",
      "down",
      "down",
      "up",
      "down",
    ])
  })

  it("holds a touch gesture open and reports direction changes", () => {
    const { container, events } = setup()
    const touch = (type: string, y?: number) =>
      container.dispatchEvent(
        new TouchEvent(type, { touches: y === undefined ? [] : ([{ clientY: y }] as unknown as Touch[]) }),
      )
    touch("touchstart", 100)
    touch("touchmove", 120)
    touch("touchmove", 140)
    touch("touchmove", 130)
    touch("touchend")
    expect(events).toEqual([
      { kind: "input", source: "touch", held: true },
      { kind: "input", source: "touch", direction: "up", held: true },
      { kind: "input", source: "touch", direction: "down", held: true },
      { kind: "inputEnd" },
    ])
  })

  it("treats a scroll during a pointer press as scrollbar input, held until release", () => {
    const { container, events } = setup()
    container.dispatchEvent(new PointerEvent("pointerdown", { button: 0, pointerType: "mouse", bubbles: true }))
    container.dispatchEvent(new Event("scroll"))
    container.dispatchEvent(new Event("scroll"))
    window.dispatchEvent(new PointerEvent("pointerup", { button: 0 }))
    expect(events.filter((event) => event.kind !== "scroll")).toEqual([
      { kind: "input", source: "scrollbar", held: true },
      { kind: "inputEnd" },
    ])
    // A click without scrolling is not scroll input.
    events.length = 0
    container.dispatchEvent(new PointerEvent("pointerdown", { button: 0, pointerType: "mouse" }))
    window.dispatchEvent(new PointerEvent("pointerup", { button: 0 }))
    expect(events).toEqual([])
  })
})

describe("dom host: modified keys", () => {
  it("does not count shortcuts with modifiers as scroll input", () => {
    const { container, events } = setup()
    const key = (init: KeyboardEventInit) => container.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, ...init }))
    // Previous chat, start or end of a line or document, extending a selection: none of these scroll the list.
    key({ key: "ArrowUp", altKey: true })
    key({ key: "ArrowUp", metaKey: true })
    key({ key: "ArrowUp", ctrlKey: true })
    key({ key: "Home", ctrlKey: true })
    key({ key: "PageDown", altKey: true })
    key({ key: "ArrowDown", shiftKey: true })
    key({ key: "PageUp", shiftKey: true })
    key({ key: " ", ctrlKey: true })
    expect(events).toEqual([])
    // Unmodified scroll keys and Shift+Space still do.
    key({ key: "ArrowUp" })
    key({ key: " ", shiftKey: true })
    expect(events).toEqual([
      { kind: "input", source: "key", direction: "up" },
      { kind: "input", source: "key", direction: "up" },
    ])
  })
})

describe("dom host: scrolling and time", () => {
  it("ends scrolling 150 ms after the last scroll event where scrollend is missing", () => {
    const { container, events, time } = setup()
    container.dispatchEvent(new Event("scroll"))
    time.advance(96)
    container.dispatchEvent(new Event("scroll"))
    time.advance(128)
    expect(events.map((event) => event.kind)).toEqual(["scroll", "scroll"])
    time.advance(32)
    expect(events.map((event) => event.kind)).toEqual(["scroll", "scroll", "scrollEnd"])
  })

  it("animates the offset on frames, lands exactly and can be cancelled", () => {
    const { container, host, time } = setup()
    let done = 0
    host.animateScroll(400, { duration: 400, easing: "easeInOut" }, () => done++)
    time.advance(208)
    expect(container.scrollTop).toBeGreaterThan(100)
    expect(container.scrollTop).toBeLessThan(300)
    time.advance(208)
    expect(container.scrollTop).toBe(400)
    expect(done).toBe(1)

    const cancel = host.animateScroll(0, { duration: 400, easing: "easeIn" }, () => done++)
    time.advance(96)
    cancel()
    const stopped = container.scrollTop
    time.advance(500)
    expect(container.scrollTop).toBe(stopped)
    expect(done).toBe(1)
  })

  it("reports activity from visibility and focus", () => {
    const { host, events } = setup()
    document.dispatchEvent(new Event("visibilitychange"))
    window.dispatchEvent(new Event("blur"))
    expect(events.map((event) => event.kind)).toEqual(["activity", "activity"])
    expect(host.activity().visible).toBe(true)
  })

  it("stops reporting after dispose", async () => {
    const { container, host, events } = setup(["a"])
    host.dispose()
    container.dispatchEvent(new WheelEvent("wheel", { deltaY: -1 }))
    container.dispatchEvent(new Event("scroll"))
    container.append(row("b"))
    await microtask()
    expect(events).toEqual([])
  })
})
