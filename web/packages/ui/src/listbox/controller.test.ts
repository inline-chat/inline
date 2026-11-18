// @vitest-environment happy-dom
import { afterEach, describe, expect, test } from "vitest"
import { click, h, mount, press } from "../testing/dom"
import { ListboxController, type ListboxOption } from "./controller"
import { SelectionModel } from "./selection"

const order = ["a", "b", "c", "d", "e"]

describe("selection model", () => {
  test("replace, toggle and Finder-style ranges", () => {
    const selection = new SelectionModel({ mode: "multiple" })
    selection.replace("a")
    selection.toggle("c")
    expect([...selection.selected.peek()]).toEqual(["a", "c"])
    selection.extendTo("e", order)
    expect([...selection.selected.peek()].sort()).toEqual(["a", "c", "d", "e"])
    selection.extendTo("d", order)
    expect([...selection.selected.peek()].sort()).toEqual(["a", "c", "d"])
    selection.extendTo("b", order)
    expect([...selection.selected.peek()].sort()).toEqual(["a", "b", "c"])
  })

  test("single mode never holds more than one; none holds nothing", () => {
    const single = new SelectionModel({ mode: "single", initial: ["a", "b"] })
    expect([...single.selected.peek()]).toEqual(["a"])
    single.toggle("c")
    single.extendTo("e", order)
    expect([...single.selected.peek()]).toEqual(["e"])
    const none = new SelectionModel({ mode: "none" })
    none.replace("a")
    expect(none.selected.peek().size).toBe(0)
  })

  test("onChange fires only for real changes", () => {
    const changes: string[][] = []
    const selection = new SelectionModel({ mode: "multiple", onChange: (next) => changes.push([...next]) })
    selection.replace("a")
    selection.replace("a")
    selection.selectAll(order)
    expect(changes).toEqual([["a"], order])
  })
})

const items: ListboxOption[] = [
  { id: "inbox", label: "Inbox" },
  { id: "archive", label: "Archive" },
  { id: "drafts", label: "Drafts", disabled: true },
  { id: "sent", label: "Sent" },
  { id: "spam", label: "Spam" },
]

const setup = (options: Partial<ConstructorParameters<typeof ListboxController>[0]> = {}) => {
  const actions: string[] = []
  const listbox = new ListboxController({
    items: () => items,
    label: "Folders",
    platform: "mac",
    onAction: (id) => actions.push(id),
    ...options,
  })
  const root = mount(h("div"))
  listbox.root.attach(root)
  for (const item of items) {
    const element = h("div", {}, item.label)
    root.append(element)
    listbox.option(item.id).attach(element)
  }
  const option = (id: string) => document.getElementById(listbox.optionDomId(id))!
  return { listbox, root, option, actions }
}

const selectedIds = (listbox: ListboxController) => [...listbox.selected.peek()]

afterEach(() => document.body.replaceChildren())

describe("listbox, single selection", () => {
  test("ARIA, focus activates the selected or first option, arrows move selection with focus", () => {
    const { listbox, root, option } = setup({ selected: ["archive"] })
    expect(root.getAttribute("role")).toBe("listbox")
    expect(root.tabIndex).toBe(0)
    expect(root.hasAttribute("aria-multiselectable")).toBe(false)
    root.focus()
    expect(root.getAttribute("aria-activedescendant")).toBe(option("archive").id)
    press("ArrowDown")
    expect(listbox.activeId.peek()).toBe("sent")
    expect(selectedIds(listbox)).toEqual(["sent"])
    expect(option("sent").getAttribute("aria-selected")).toBe("true")
    expect(option("archive").getAttribute("aria-selected")).toBe("false")
    expect(option("drafts").getAttribute("aria-disabled")).toBe("true")
    press("Home")
    expect(selectedIds(listbox)).toEqual(["inbox"])
    press("End")
    expect(selectedIds(listbox)).toEqual(["spam"])
  })

  test("typeahead, Enter runs the action, clicks select", () => {
    const { listbox, root, option, actions } = setup()
    root.focus()
    press("s")
    expect(listbox.activeId.peek()).toBe("sent")
    press("p")
    expect(listbox.activeId.peek()).toBe("spam")
    press("Enter")
    expect(actions).toEqual(["spam"])
    click(option("archive"))
    expect(selectedIds(listbox)).toEqual(["archive"])
    click(option("drafts"))
    expect(selectedIds(listbox)).toEqual(["archive"])
  })
})

describe("listbox, multiple selection", () => {
  test("Shift+arrows extend, the platform modifier toggles on click, Shift+click ranges", () => {
    const { listbox, root, option } = setup({ selectionMode: "multiple" })
    expect(root.getAttribute("aria-multiselectable")).toBe("true")
    root.focus()
    expect(listbox.activeId.peek()).toBe("inbox")
    press("ArrowDown")
    press("ArrowDown", { shiftKey: true })
    expect(selectedIds(listbox).sort()).toEqual(["archive", "sent"])
    click(option("inbox"), { metaKey: true })
    expect(selectedIds(listbox).sort()).toEqual(["archive", "inbox", "sent"])
    click(option("inbox"), { ctrlKey: true })
    expect(selectedIds(listbox)).toEqual(["inbox"])
    click(option("spam"), { shiftKey: true })
    expect(selectedIds(listbox).sort()).toEqual(["archive", "inbox", "sent", "spam"])
  })

  test("Cmd+A selects all enabled options; Space toggles when selection does not follow focus", () => {
    const { listbox, root } = setup({ selectionMode: "multiple", selectionFollowsFocus: false })
    root.focus()
    press("a", { metaKey: true })
    expect(selectedIds(listbox)).toEqual(["inbox", "archive", "sent", "spam"])
    press("ArrowDown")
    expect(listbox.activeId.peek()).toBe("archive")
    press(" ")
    expect(selectedIds(listbox)).toEqual(["inbox", "sent", "spam"])
    press(" ")
    expect(selectedIds(listbox).sort()).toEqual(["archive", "inbox", "sent", "spam"])
  })

  test("Ctrl is the modifier on other platforms", () => {
    const { listbox, root, option } = setup({ selectionMode: "multiple", platform: "other" })
    root.focus()
    click(option("inbox"))
    click(option("sent"), { ctrlKey: true })
    expect(selectedIds(listbox)).toEqual(["inbox", "sent"])
    press("a", { ctrlKey: true })
    expect(selectedIds(listbox)).toHaveLength(4)
  })
})
