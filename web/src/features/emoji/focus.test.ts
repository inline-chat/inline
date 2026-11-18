// @vitest-environment happy-dom
/**
 * The pickers' popovers in a DOM: focus moving in on open (and staying in
 * the row when the row renders after the open), keys and typing reaching
 * the right place, focus returning to the opener on close, and a picker
 * opened before its anchor is laid out waiting for it. The views are
 * mirrored by hand (StyleX needs its compiler, which the test run lacks):
 * the same elements, attributes and parts as `ReactionPicker.tsx`,
 * `EmojiPicker.tsx` and `ComposerEmojiButton.tsx`. Frames are injected.
 */

import { afterEach, describe, expect, it } from "vitest"
import { ComposerEmojiPicker } from "./composer-picker"
import { createEmojiEngine } from "./engine"
import type { FrameScheduler } from "./frame"
import type { EmojiPickerController } from "./picker"
import { ReactionPickerController } from "./reaction-picker"
import { createEmojiServices } from "./services"
import { createEmojiSupport } from "./support"
import { memoryKeyValueStore } from "./usage"

const engine = createEmojiEngine()

const services = () =>
  createEmojiServices({
    store: memoryKeyValueStore(),
    now: () => Date.UTC(2026, 10, 17),
    importEngine: () => Promise.resolve(engine),
    support: createEmojiSupport({ probe: () => undefined }),
  })

const manualFrames = () => {
  const queue: (() => void)[] = []
  const frame: FrameScheduler = (callback) => {
    queue.push(callback)
  }
  const run = () => {
    for (const callback of queue.splice(0)) callback()
  }
  return { frame, run, pending: () => queue.length }
}

const element = <K extends keyof HTMLElementTagNameMap>(tag: K, attrs: Record<string, string> = {}, ...children: Node[]) => {
  const node = document.createElement(tag)
  for (const [name, value] of Object.entries(attrs)) node.setAttribute(name, value)
  node.append(...children)
  return node
}

const setRect = (target: Element, x: number, y: number, width: number, height: number) => {
  target.getBoundingClientRect = () => DOMRect.fromRect({ x, y, width, height })
}

/** A key where focus is, as a keyboard would. */
const press = (key: string) => {
  const event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, composed: true })
  ;(document.activeElement ?? document.body).dispatchEvent(event)
  return event
}

/** The full picker's search field, as `EmojiPicker.tsx` renders it. */
const renderFullPicker = (container: HTMLElement, picker: EmojiPickerController) => {
  const search = element("input", { type: "search" })
  container.replaceChildren(element("div", { "data-emoji-picker": "" }, search))
  return { search, detach: picker.search.attach(search) }
}

afterEach(() => document.body.replaceChildren())

describe("reaction picker focus", () => {
  /**
   * `ReactionPickerView` in its popover: a row of buttons with
   * `data-quick-index` (the plus last), one tab stop at the controller's
   * focus index. `renderRow` re-renders it the way a view that draws the row
   * after the open does: new buttons for a new row.
   */
  const setup = () => {
    const frames = manualFrames()
    const opener = element("button", { "data-lab": "add-reaction" }, document.createTextNode("Add Reaction"))
    setRect(opener, 40, 400, 96, 24)
    document.body.append(opener)
    const chosen: string[] = []
    const emoji = services()
    const controller = new ReactionPickerController({
      services: emoji,
      anchor: () => opener,
      direction: () => "ltr",
      frame: frames.frame,
      onChoose: (emoji) => chosen.push(emoji),
    })
    const content = element("div", { popover: "manual" })
    const row = element("div")
    content.append(row)
    document.body.append(content)
    const detachContent = controller.popover.content.attach(content)
    let detachRow = controller.row.attach(row)
    const renderRow = () => {
      const items = controller.quick.peek()
      const focus = controller.focusIndex.peek()
      const buttons = items.map((item, index) => {
        const button = element("button", { type: "button", "data-quick-index": String(index), "aria-label": `React with ${item.emoji}` })
        button.tabIndex = focus === index ? 0 : -1
        button.addEventListener("click", () => controller.choose(item.emoji))
        return button
      })
      const more = element("button", { type: "button", "data-quick-index": String(items.length), "aria-label": "More reactions" })
      more.tabIndex = focus === items.length ? 0 : -1
      row.replaceChildren(...buttons, more)
    }
    renderRow()
    const showFull = () => {
      detachRow()
      detachRow = () => undefined
      const picker = controller.full.peek()
      if (!picker) throw new Error("full picker not built")
      return renderFullPicker(content, picker)
    }
    const cleanup = () => {
      detachRow()
      detachContent()
      controller.dispose()
    }
    return { controller, emoji, opener, content, row, frames, renderRow, showFull, chosen, cleanup }
  }

  it("opening puts focus on the active quick reaction, even when the row renders after the open; keys, typing and Escape work from there", async () => {
    const { controller, emoji, opener, content, row, frames, renderRow, showFull, cleanup } = setup()
    await emoji.loader.load() // the data, as after the app's warm-up
    controller.open({ messageText: "Shipped 🚀 thanks 🎉", mine: ["👍"] })
    expect(controller.popover.isOpen.peek()).toBe(true)
    // The view draws the row for this message after the open (new buttons).
    renderRow()
    frames.run()
    const active = () => document.activeElement
    expect(content.contains(active())).toBe(true)
    expect(active()?.getAttribute("data-quick-index")).toBe("0")
    expect(active()?.getAttribute("aria-label")).toBe("React with 🚀")

    // Arrows rove from there.
    expect(press("ArrowRight").defaultPrevented).toBe(true)
    expect(controller.focusIndex.peek()).toBe(1)
    expect(active()).toBe(row.querySelectorAll("[data-quick-index]")[1])

    // A letter opens the full picker searching for it, and focus lands in its search field.
    press("r")
    expect(controller.mode.peek()).toBe("full")
    const { search } = showFull()
    expect(active()).toBe(search)
    expect(search.value).toBe("r")

    // Escape clears the search first, then closes and returns focus to the opener.
    press("Escape")
    expect(controller.popover.isOpen.peek()).toBe(true)
    expect(search.value).toBe("")
    press("Escape")
    expect(controller.popover.isOpen.peek()).toBe(false)
    expect(active()).toBe(opener)
    cleanup()
  })

  it("choosing, and a press outside, return focus to the opener too", () => {
    const { controller, opener, frames, renderRow, chosen, cleanup } = setup()
    controller.open({ messageText: "🎉" })
    renderRow()
    frames.run()
    press("Enter")
    expect(chosen).toEqual(["🎉"])
    expect(controller.popover.isOpen.peek()).toBe(false)
    expect(document.activeElement).toBe(opener)

    controller.open({ messageText: "🎉" })
    frames.run()
    expect(document.activeElement?.getAttribute("data-quick-index")).toBe("0")
    const outside = element("div")
    document.body.append(outside)
    outside.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, cancelable: true, button: 0 }))
    expect(controller.popover.isOpen.peek()).toBe(false)
    expect(document.activeElement).toBe(opener)
    cleanup()
  })

  it("leaves focus alone when the user moved it into the row already", () => {
    const { controller, row, frames, renderRow, cleanup } = setup()
    controller.open()
    renderRow()
    ;(row.querySelectorAll<HTMLElement>("[data-quick-index]")[2] as HTMLElement).focus()
    frames.run()
    expect(controller.focusIndex.peek()).toBe(2)
    expect(document.activeElement?.getAttribute("data-quick-index")).toBe("2")
    cleanup()
  })
})

describe("opening before the anchor is laid out", () => {
  it("the reaction picker opens on the first frame its anchor can be placed, and is placed there", () => {
    const frames = manualFrames()
    let anchor: HTMLElement | null = null
    const controller = new ReactionPickerController({
      services: services(),
      anchor: () => anchor,
      direction: () => "ltr",
      frame: frames.frame,
      onChoose: () => undefined,
    })
    const content = element("div", { popover: "manual" }, element("div"))
    document.body.append(content)
    const detach = controller.popover.content.attach(content)

    // At start-up: no anchor in the document yet.
    controller.open()
    expect(controller.popover.isOpen.peek()).toBe(false)
    expect(content.style.top).toBe("")
    frames.run()
    expect(controller.popover.isOpen.peek()).toBe(false)

    // In the document but not laid out (a zero rectangle): still waiting.
    anchor = element("button")
    document.body.append(anchor)
    frames.run()
    expect(controller.popover.isOpen.peek()).toBe(false)

    // Laid out: opens on this frame, placed above it at its start.
    setRect(anchor, 120, 300, 96, 24)
    frames.run()
    expect(controller.popover.isOpen.peek()).toBe(true)
    expect(content.getAttribute("data-side")).toBe("top")
    expect(content.style.left).toBe("120px")
    expect(content.style.top).not.toBe("")
    expect(frames.pending()).toBeLessThanOrEqual(1) // only the focus hand-off

    // A close while waiting cancels the open.
    controller.close()
    anchor.remove()
    controller.open()
    controller.close()
    document.body.append(anchor)
    frames.run()
    expect(controller.popover.isOpen.peek()).toBe(false)
    detach()
    controller.dispose()
  })

  it("gives up waiting after a while and opens anyway", () => {
    const frames = manualFrames()
    const controller = new ReactionPickerController({ services: services(), anchor: () => null, frame: frames.frame, onChoose: () => undefined })
    controller.open()
    for (let index = 0; index < 40 && !controller.popover.isOpen.peek(); index++) frames.run()
    expect(controller.popover.isOpen.peek()).toBe(true)
    controller.dispose()
  })
})

describe("composer emoji button focus", () => {
  it("opened from code before the button is laid out, it waits; focus goes in, then to the search field; Escape returns it to the button", async () => {
    const frames = manualFrames()
    const inserted: string[] = []
    const composer = new ComposerEmojiPicker({ services: services(), onInsert: (emoji) => inserted.push(emoji), frame: frames.frame })
    const content = element("div", { popover: "manual" })
    document.body.append(content)
    const detachContent = composer.popover.content.attach(content)

    composer.open()
    expect(composer.popover.isOpen.peek()).toBe(false)
    const button = element("button", { "aria-label": "Emoji" })
    document.body.append(button)
    setRect(button, 600, 700, 28, 28)
    const detachButton = composer.trigger.attach(button)
    frames.run()
    expect(composer.popover.isOpen.peek()).toBe(true)
    expect(content.getAttribute("data-side")).toBe("top")
    // The placeholder has nothing to focus: the popover itself holds focus.
    expect(document.activeElement).toBe(content)

    // The data arrives and the view draws the picker: the search field takes focus.
    await Promise.resolve()
    await Promise.resolve()
    const picker = composer.picker.peek()
    expect(picker).toBeDefined()
    const { search } = renderFullPicker(content, picker as EmojiPickerController)
    expect(document.activeElement).toBe(search)

    press("Escape")
    expect(composer.popover.isOpen.peek()).toBe(false)
    expect(document.activeElement).toBe(button)

    // A click on the button opens at once (it is laid out).
    button.click()
    expect(composer.popover.isOpen.peek()).toBe(true)
    detachButton()
    detachContent()
    composer.dispose()
  })
})
