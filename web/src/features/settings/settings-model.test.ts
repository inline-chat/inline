import { createManualClock } from "@inline/ui"
import type { SettingsPage } from "@inline/view"
import { describe, expect, it } from "vitest"
import { REVEAL_HIGHLIGHT_MS, SettingsModel } from "./settings-model"

const setup = (page?: SettingsPage, hasAccount = true) => {
  const clock = createManualClock()
  const navigations: SettingsPage[] = []
  const model = new SettingsModel({
    page,
    hasAccount,
    clock,
    platform: "mac",
    onNavigate: (next) => navigations.push(next),
  })
  return { model, clock, navigations }
}

/** A row element as the model sees it: scrolls, and holds one focusable control. */
const fakeRow = () => {
  const log: string[] = []
  const control = { focus: () => log.push("focus") }
  const element = {
    scrollIntoView: () => log.push("scroll"),
    querySelector: () => control,
  }
  return { element: element as unknown as HTMLElement, log }
}

const selected = (model: SettingsModel) => [...model.pageList.selection.selected.peek()]

describe("SettingsModel: pages and the destination", () => {
  it("opens General for /settings, showing the list at a narrow width", () => {
    const { model } = setup(undefined)
    expect(model.resolved.peek()).toEqual({ kind: "page", id: "general" })
    expect(selected(model)).toEqual(["general"])
    expect(model.narrowView.peek()).toBe("list")
  })

  it("shows the page column for a link to a page", () => {
    const { model } = setup("appearance")
    expect(selected(model)).toEqual(["appearance"])
    expect(model.narrowView.peek()).toBe("page")
  })

  it("arrows through the list navigate without leaving the list at a narrow width", () => {
    const { model, navigations } = setup(undefined)
    model.pageList.setActive("general")
    model.pageList.handleKeyDown({ key: "ArrowDown" })
    expect(navigations).toEqual(["appearance"])
    // The shell navigates; the destination comes back as an echo.
    model.syncDestination("appearance")
    expect(selected(model)).toEqual(["appearance"])
    expect(model.narrowView.peek()).toBe("list")
    expect(navigations).toEqual(["appearance"])
  })

  it("Enter on a page shows it", () => {
    const { model, navigations } = setup(undefined)
    model.pageList.setActive("notifications")
    model.pageList.handleKeyDown({ key: "Enter" })
    expect(navigations).toEqual(["notifications"])
    expect(model.narrowView.peek()).toBe("page")
  })

  it("follows Back and Forward without navigating again", () => {
    const { model, navigations } = setup("appearance")
    model.syncDestination("data")
    expect(selected(model)).toEqual(["data"])
    // No keyboard cursor until the list has been used.
    expect(model.pageList.activeId.peek()).toBe(null)
    model.pageList.setActive("data")
    model.syncDestination("notifications")
    expect(model.pageList.activeId.peek()).toBe("notifications")
    model.syncDestination("data")
    expect(model.narrowView.peek()).toBe("page")
    model.syncDestination(undefined)
    expect(selected(model)).toEqual(["general"])
    expect(model.narrowView.peek()).toBe("list")
    expect(navigations).toEqual([])
  })

  it("selects nothing for a Mac page the web does not have", () => {
    const { model } = setup("privacy")
    expect(model.resolved.peek()).toEqual({ kind: "unavailable", page: "privacy", title: "Privacy" })
    expect(selected(model)).toEqual([])
  })

  it("leaves Account out without an account", () => {
    const { model } = setup(undefined, false)
    expect(model.pages.map((page) => page.id)).not.toContain("account")
    expect(model.resolved.peek()).toEqual({ kind: "page", id: "general" })
  })

  it("the destination part syncs when attached and is cached per page", () => {
    const { model } = setup("general")
    const part = model.destination("updates")
    expect(model.destination("updates")).toBe(part)
    part.attach({} as HTMLElement)
    expect(selected(model)).toEqual(["updates"])
  })

  it("the back control shows the list", () => {
    const { model } = setup("appearance")
    model.showList()
    expect(model.narrowView.peek()).toBe("list")
  })
})

describe("SettingsModel: search and reveal", () => {
  it("searches as the query changes and activates the first result", () => {
    const { model } = setup("general")
    model.setQuery("spell")
    expect(model.searching.peek()).toBe(true)
    expect(model.results.peek().map((result) => result.id)).toEqual(["checkSpelling"])
    expect(model.resultList.activeId.peek()).toBe("checkSpelling")
    model.setQuery("   ")
    expect(model.searching.peek()).toBe(false)
    expect(model.results.peek()).toEqual([])
  })

  it("Enter reveals a row on another page once its page renders", () => {
    const { model, clock, navigations } = setup("appearance")
    model.setQuery("send")
    expect(model.handleSearchKey({ key: "Enter", shiftKey: false, altKey: false, ctrlKey: false, metaKey: false })).toBe(true)
    expect(navigations).toEqual(["general"])
    model.syncDestination("general")
    const row = fakeRow()
    model.row("sendMessages").attach(row.element)
    expect(row.log).toEqual([])
    clock.advance(0)
    expect(row.log).toEqual(["scroll", "focus"])
    expect(model.isHighlighted("sendMessages").peek()).toBe(true)
    clock.advance(REVEAL_HIGHLIGHT_MS)
    expect(model.isHighlighted("sendMessages").peek()).toBe(false)
  })

  it("reveals a row on the current page without navigating", () => {
    const { model, clock, navigations } = setup("general")
    const row = fakeRow()
    model.row("checkSpelling").attach(row.element)
    model.reveal("checkSpelling")
    clock.advance(0)
    expect(navigations).toEqual([])
    expect(row.log).toEqual(["scroll"])
    expect(model.narrowView.peek()).toBe("page")
  })

  it("arrows move through the results and Escape clears the query", () => {
    const { model } = setup("general")
    model.setQuery("badge")
    expect(model.resultList.activeId.peek()).toBe("unreadBadgeStyle")
    const key = (name: string) => model.handleSearchKey({ key: name, shiftKey: false, altKey: false, ctrlKey: false, metaKey: false })
    expect(key("ArrowDown")).toBe(true)
    expect(model.resultList.activeId.peek()).toBe("appBadge")
    expect(key("a")).toBe(false)
    expect(key("Escape")).toBe(true)
    expect(model.query.peek()).toBe("")
    // With no query, Escape is left to the app.
    expect(key("Escape")).toBe(false)
  })

  it("a clicked result reveals it", () => {
    const { model, navigations } = setup("general")
    model.setQuery("theme")
    model.resultList.handleKeyDown({ key: "Enter" })
    expect(navigations).toEqual(["appearance"])
  })

  it("ignores rows on pages that are not listed, and unknown rows", () => {
    const { model, navigations } = setup("general", false)
    model.reveal("thisDevice")
    model.reveal("nope")
    expect(navigations).toEqual([])
  })

  it("a later reveal moves the highlight", () => {
    const { model, clock } = setup("general")
    const a = fakeRow()
    const b = fakeRow()
    model.row("checkSpelling").attach(a.element)
    model.row("sendMessages").attach(b.element)
    model.reveal("checkSpelling")
    clock.advance(0)
    model.reveal("sendMessages")
    clock.advance(0)
    expect(model.isHighlighted("checkSpelling").peek()).toBe(false)
    expect(model.isHighlighted("sendMessages").peek()).toBe(true)
  })

  it("dispose cancels pending work", () => {
    const { model, clock } = setup("general")
    const row = fakeRow()
    model.row("checkSpelling").attach(row.element)
    model.reveal("checkSpelling")
    model.dispose()
    clock.advance(10_000)
    expect(row.log).toEqual([])
    expect(clock.pending()).toBe(0)
  })
})
