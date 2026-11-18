// @vitest-environment happy-dom
import { afterEach, describe, expect, test } from "vitest"
import { openLayerCount } from "../foundations/dismiss"
import { h, keydown, mount, pointer, press } from "../testing/dom"
import { createSheet, type DialogCloseReason, DialogController } from "./controller"

const setup = (controller: DialogController) => {
  const opener = mount(h("button", {}, "Open"))
  const title = h("h2", {}, "Rename chat")
  const description = h("p", {}, "Choose a new name")
  const input = h("input", { id: "name" })
  const save = h("button", { id: "save" }, "Save")
  const surface = h("div", {}, title, description, input, save)
  const dialog = mount(h("dialog", {}, surface)) as HTMLDialogElement
  const outside = mount(h("button", {}, "outside"))
  controller.content.attach(dialog)
  controller.surface.attach(surface)
  controller.title.attach(title)
  controller.description.attach(description)
  return { opener, dialog, surface, input, save, outside }
}

afterEach(() => document.body.replaceChildren())

describe("dialog", () => {
  test("opens modally with ARIA wired, focuses the first field, and restores focus on close", () => {
    const reasons: DialogCloseReason[] = []
    const controller = new DialogController({ onClose: (reason) => reasons.push(reason) })
    const { opener, dialog, input } = setup(controller)
    opener.focus()
    controller.open()
    expect(dialog.open).toBe(true)
    expect(dialog.getAttribute("role")).toBe("dialog")
    expect(dialog.getAttribute("aria-modal")).toBe("true")
    expect(dialog.getAttribute("aria-labelledby")).toBe(controller.titleId)
    expect(dialog.getAttribute("aria-describedby")).toBe(controller.descriptionId)
    expect(document.activeElement).toBe(input)
    controller.close("button")
    expect(dialog.open).toBe(false)
    expect(document.activeElement).toBe(opener)
    expect(reasons).toEqual(["button"])
  })

  test("Tab wraps inside the dialog", () => {
    const controller = new DialogController()
    const { input, save } = setup(controller)
    controller.open()
    save.focus()
    press("Tab")
    expect(document.activeElement).toBe(input)
    press("Tab", { shiftKey: true })
    expect(document.activeElement).toBe(save)
    controller.dispose()
  })

  test("Escape closes, as does the native cancel event, without the platform closing it behind our back", () => {
    const controller = new DialogController()
    const { opener, dialog } = setup(controller)
    opener.focus()
    controller.open()
    press("Escape")
    expect(controller.isOpen.peek()).toBe(false)
    expect(document.activeElement).toBe(opener)
    controller.open()
    const cancel = new Event("cancel", { cancelable: true })
    dialog.dispatchEvent(cancel)
    expect(cancel.defaultPrevented).toBe(true)
    expect(controller.isOpen.peek()).toBe(false)
  })

  test("a backdrop press closes a dialog but not a sheet or an alert dialog", () => {
    const dialog = new DialogController()
    const first = setup(dialog)
    dialog.open()
    pointer(first.surface, "pointerdown")
    expect(dialog.isOpen.peek()).toBe(true)
    pointer(first.dialog, "pointerdown")
    expect(dialog.isOpen.peek()).toBe(false)

    document.body.replaceChildren()
    const sheet = createSheet()
    const second = setup(sheet)
    sheet.open()
    expect(second.dialog.getAttribute("data-presentation")).toBe("sheet")
    pointer(second.dialog, "pointerdown")
    expect(sheet.isOpen.peek()).toBe(true)
    sheet.dispose()

    document.body.replaceChildren()
    const alert = new DialogController({ role: "alertdialog" })
    const third = setup(alert)
    alert.open()
    pointer(third.dialog, "pointerdown")
    expect(alert.isOpen.peek()).toBe(true)
    expect(third.dialog.getAttribute("role")).toBe("alertdialog")
    alert.dispose()
    expect(openLayerCount(document)).toBe(0)
  })

  test("closeOnEscape false keeps it open; a form method=dialog close syncs state", () => {
    const controller = new DialogController({ closeOnEscape: false })
    const { dialog } = setup(controller)
    controller.open()
    keydown(dialog, "Escape")
    expect(controller.isOpen.peek()).toBe(true)
    dialog.close()
    dialog.dispatchEvent(new Event("close"))
    expect(controller.isOpen.peek()).toBe(false)
  })
})
