import { ContextMenuController, Lazy, type MenuKitCore } from "@inline/ui"
import { describe, expect, it } from "vitest"
import { MessageActionsController, menuEntries, quickActions, type MessageAction } from "./actions"

describe("row actions", () => {
  const ran: string[] = []
  const action = (id: string, extra: Partial<MessageAction> = {}): MessageAction => ({
    id,
    label: id,
    enabled: true,
    run: ({ rowId, via }) => ran.push(`${id}:${rowId}:${via}`),
    ...extra,
  })

  it("builds menu entries with separators between groups and disabled items kept", () => {
    const entries = menuEntries(
      [
        action("reply", { group: "a", shortcut: "R" }),
        action("copy", { group: "a" }),
        action("edit", { group: "b", enabled: false }),
        action("delete", { group: "c", destructive: true }),
      ],
      "7:1",
    )
    expect(entries.map((entry) => entry.type)).toEqual(["item", "item", "separator", "item", "separator", "item"])
    expect(entries[0]).toMatchObject({ id: "reply", shortcut: "R", disabled: false })
    expect(entries[3]).toMatchObject({ id: "edit", disabled: true })
    expect(entries[5]).toMatchObject({ id: "delete", destructive: true })
    const first = entries[0]
    if (first?.type === "item") first.onSelect?.()
    expect(ran.at(-1)).toBe("reply:7:1:menu")
  })

  it("selects quick actions in order", () => {
    const actions = [action("reply", { quick: true }), action("copy"), action("react", { quick: true })]
    expect(quickActions(actions).map((a) => a.id)).toEqual(["reply", "react"])
  })

  it("marks one row active from hover or keyboard focus, through cached per-row signals", () => {
    const controller = new MessageActionsController({ actionsFor: () => [action("reply", { quick: true })] })
    const a = controller.isActive("7:1")
    const b = controller.isActive("7:2")
    expect(controller.isActive("7:1")).toBe(a)
    expect(a.peek()).toBe(false)
    controller.setHovered("7:1")
    expect(a.peek()).toBe(true)
    expect(b.peek()).toBe(false)
    controller.setFocused("7:2")
    expect(a.peek()).toBe(true)
    expect(b.peek()).toBe(true)
    controller.setHovered(null)
    expect(a.peek()).toBe(false)

    controller.runQuick("7:2", action("react"))
    expect(ran.at(-1)).toBe("react:7:2:quick")
    controller.runQuick("7:2", action("off", { enabled: false }))
    expect(ran.at(-1)).toBe("react:7:2:quick")
    controller.dispose()
  })
})

describe("row menu, loaded on first use", () => {
  const actions = (): MessageAction[] => [
    { id: "edit", label: "Edit", shortcut: "⌘E", enabled: true, run: () => {} },
    { id: "delete", label: "Delete", shortcut: "⌘⌫", keyshortcuts: "Meta+Backspace", enabled: true, destructive: true, run: () => {} },
  ]

  it("passes shortcuts to the menu as hints and aria-keyshortcuts", () => {
    const entries = menuEntries(actions(), "7:1")
    expect(entries[0]).toMatchObject({ label: "Edit", shortcut: "⌘E" })
    expect(entries[0]).not.toHaveProperty("keyshortcuts")
    expect(entries[1]).toMatchObject({ label: "Delete", shortcut: "⌘⌫", keyshortcuts: "Meta+Backspace" })
  })

  it("loads no menu code until asked; More Actions before the code arrives opens once it does", async () => {
    let arrive: () => void = () => {}
    let loads = 0
    const kit = new Lazy<MenuKitCore>(() => {
      loads++
      return new Promise((resolve) => (arrive = () => resolve({ ContextMenuController })))
    })
    const controller = new MessageActionsController({ actionsFor: actions, menuKit: kit })
    expect(loads).toBe(0)
    expect(controller.contextMenu.controller.peek()).toBeUndefined()
    controller.openMenu("7:1", { x: 10, y: 20, width: 24, height: 24 })
    expect(loads).toBe(1)
    expect(controller.menuRowId.peek()).toBe("7:1")
    expect(controller.isActive("7:1").peek()).toBe(true)
    arrive()
    await kit.load()
    await Promise.resolve()
    const menu = controller.contextMenu.controller.peek()?.menu
    expect(menu?.isOpen.peek()).toBe(true)
    expect(menu?.entries.peek().map((entry) => entry.id)).toEqual(["edit", "delete"])
    menu?.close()
    expect(controller.menuRowId.peek()).toBeNull()
    controller.dispose()
  })

  it("warmMenu loads the code ahead of the first request", async () => {
    const kit = new Lazy<MenuKitCore>(async () => ({ ContextMenuController }))
    const controller = new MessageActionsController({ actionsFor: actions, menuKit: kit })
    await controller.warmMenu()
    expect(controller.contextMenu.controller.peek()).toBeDefined()
    controller.dispose()
  })
})

describe("reaction picker anchor", () => {
  it("keeps the row active while a picker is anchored to it", () => {
    const controller = new MessageActionsController({ actionsFor: () => [] })
    const row = controller.isActive("7:3")
    controller.setHovered("7:3")
    controller.setPickerAnchor("7:3", { x: 1, y: 2, width: 3, height: 4 })
    // The pointer leaves the row for the picker: the capsule (the anchor) stays.
    controller.setHovered(null)
    expect(row.peek()).toBe(true)
    expect(controller.pickerAnchor.peek()).toEqual({ rowId: "7:3", rect: { x: 1, y: 2, width: 3, height: 4 } })
    controller.setPickerAnchor(null)
    expect(row.peek()).toBe(false)
    controller.dispose()
  })
})
