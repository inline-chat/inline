import { chatId, messageId } from "@inline/ids"
import { effect } from "@inline/reactive"
import { describe, expect, test } from "vitest"
import type { Destination } from "./destination"
import { Workspace, type WorkspaceChange } from "./workspace"

const chat = (id: string): Destination => ({ kind: "chat", chatId: chatId(id) })

const make = (options: ConstructorParameters<typeof Workspace>[0] = {}) => {
  const workspace = new Workspace({ createId: () => "ws", ...options })
  const changes: WorkspaceChange[] = []
  workspace.subscribe((change) => changes.push(change))
  return { workspace, changes }
}

const shown = (workspace: Workspace) => workspace.panes.peek().map((pane) => workspace.destination(pane.id))

describe("one pane", () => {
  test("starts with the initial destination", () => {
    const { workspace } = make({ initial: chat("1") })
    expect(workspace.panes.peek()).toHaveLength(1)
    expect(workspace.focusedDestination.peek()).toEqual(chat("1"))
    expect(workspace.canGoBack.peek()).toBe(false)
  })

  test("open here pushes; back and forward walk the history", () => {
    const { workspace, changes } = make()
    workspace.open(chat("1"))
    workspace.open(chat("2"))
    expect(workspace.focusedDestination.peek()).toEqual(chat("2"))
    expect(workspace.back()).toBe(true)
    expect(workspace.focusedDestination.peek()).toEqual(chat("1"))
    expect(workspace.canGoForward.peek()).toBe(true)
    expect(workspace.forward()).toBe(true)
    expect(workspace.focusedDestination.peek()).toEqual(chat("2"))
    expect(workspace.forward()).toBe(false)
    expect(changes.map((c) => c.kind)).toEqual(["push", "push", "move", "move"])
  })

  test("opening after going back drops the forward entries", () => {
    const { workspace } = make()
    workspace.open(chat("1"))
    workspace.open(chat("2"))
    workspace.back()
    workspace.open(chat("3"))
    expect(workspace.canGoForward.peek()).toBe(false)
    expect(workspace.backEntries().map((e) => e.destination)).toEqual([chat("1"), { kind: "empty" }])
  })

  test("opening what is already shown is a no-op", () => {
    const { workspace, changes } = make({ initial: chat("1") })
    const result = workspace.open(chat("1"))
    expect(result).toMatchObject({ kind: "pane", changed: false })
    expect(changes).toEqual([])
    expect(workspace.canGoBack.peek()).toBe(false)
  })

  test("a message in the shown chat is a new entry", () => {
    const { workspace } = make({ initial: chat("1") })
    workspace.open({ kind: "message", chatId: chatId("1"), messageId: messageId("5") })
    expect(workspace.canGoBack.peek()).toBe(true)
  })

  test("replace changes the current entry without history", () => {
    const { workspace, changes } = make({ initial: chat("1") })
    workspace.open(chat("2"))
    expect(workspace.replace(chat("3"))).toBe(true)
    expect(workspace.focusedDestination.peek()).toEqual(chat("3"))
    workspace.back()
    expect(workspace.focusedDestination.peek()).toEqual(chat("1"))
    expect(changes.map((c) => c.kind)).toEqual(["push", "replace", "move"])
  })

  test("history is capped per pane, dropping the oldest", () => {
    const { workspace } = make({ historyLimit: 3 })
    for (const id of ["1", "2", "3", "4", "5"]) workspace.open(chat(id))
    const pane = workspace.focusedPane.peek()
    expect(pane.entries.map((e) => e.destination)).toEqual([chat("3"), chat("4"), chat("5")])
    expect(pane.index).toBe(2)
  })

  test("the history menu lists the nearest ten entries", () => {
    const { workspace } = make()
    for (let i = 1; i <= 15; i++) workspace.open(chat(String(i)))
    const back = workspace.backEntries()
    expect(back).toHaveLength(10)
    expect(back[0]?.destination).toEqual(chat("14"))
    workspace.goToEntry(workspace.focusedPaneId.peek(), back[2]?.id ?? "")
    expect(workspace.focusedDestination.peek()).toEqual(chat("12"))
    expect(workspace.forwardEntries()[0]?.destination).toEqual(chat("13"))
  })

  test("signals update observers once per navigation", () => {
    const { workspace } = make()
    const seen: string[] = []
    const dispose = effect(() => {
      const destination = workspace.focusedDestination.get()
      seen.push(destination.kind === "chat" ? destination.chatId : destination.kind)
    })
    workspace.open(chat("1"))
    workspace.open(chat("2"))
    workspace.back()
    dispose()
    expect(seen).toEqual(["empty", "1", "2", "1"])
  })
})

describe("open intents", () => {
  test("otherPane creates a second pane and focuses it", () => {
    const { workspace, changes } = make({ initial: chat("1") })
    const result = workspace.open(chat("2"), { intent: "otherPane" })
    expect(result).toMatchObject({ kind: "pane", changed: true })
    expect(shown(workspace)).toEqual([chat("1"), chat("2")])
    expect(workspace.focusedDestination.peek()).toEqual(chat("2"))
    expect(changes.map((c) => c.kind)).toEqual(["push"])
  })

  test("otherPane reuses the existing other pane, pushing onto its history", () => {
    const { workspace } = make({ initial: chat("1") })
    workspace.open(chat("2"), { intent: "otherPane" })
    workspace.focus(workspace.panes.peek()[0]?.id ?? "")
    workspace.open(chat("3"), { intent: "otherPane" })
    expect(shown(workspace)).toEqual([chat("1"), chat("3")])
    expect(workspace.canGoBack.peek()).toBe(true)
    workspace.back()
    expect(shown(workspace)).toEqual([chat("1"), chat("2")])
  })

  test("otherPane from the rightmost pane goes left", () => {
    const { workspace } = make({ initial: chat("1") })
    workspace.open(chat("2"), { intent: "otherPane" })
    workspace.open(chat("3"), { intent: "otherPane" })
    expect(shown(workspace)).toEqual([chat("3"), chat("2")])
  })

  test("otherPane without focus leaves focus where it was", () => {
    const { workspace } = make({ initial: chat("1") })
    const first = workspace.focusedPaneId.peek()
    workspace.open(chat("2"), { intent: "otherPane", focus: false })
    expect(workspace.focusedPaneId.peek()).toBe(first)
    expect(workspace.focusedDestination.peek()).toEqual(chat("1"))
  })

  test("newPane inserts right of the focused pane, up to the limit", () => {
    const { workspace } = make({ initial: chat("1"), maxPanes: 3 })
    workspace.open(chat("2"), { intent: "newPane" })
    workspace.focus(workspace.panes.peek()[0]?.id ?? "")
    workspace.open(chat("3"), { intent: "newPane" })
    expect(shown(workspace)).toEqual([chat("1"), chat("3"), chat("2")])
    // At the limit, newPane behaves like otherPane.
    workspace.open(chat("4"), { intent: "newPane" })
    expect(workspace.panes.peek()).toHaveLength(3)
    expect(shown(workspace)).toEqual([chat("1"), chat("3"), chat("4")])
  })

  test("with one pane allowed, otherPane opens here", () => {
    const { workspace } = make({ initial: chat("1"), maxPanes: 1 })
    workspace.open(chat("2"), { intent: "otherPane" })
    expect(shown(workspace)).toEqual([chat("2")])
  })

  test("newTab and newWindow go to the opener", () => {
    const opened: [Destination, string][] = []
    const { workspace, changes } = make({ initial: chat("1"), opener: (d, target) => opened.push([d, target]) })
    expect(workspace.open(chat("2"), { intent: "newTab" })).toEqual({ kind: "delegated", intent: "newTab" })
    expect(workspace.open(chat("3"), { intent: "newWindow" })).toEqual({ kind: "delegated", intent: "newWindow" })
    expect(opened).toEqual([
      [chat("2"), "newTab"],
      [chat("3"), "newWindow"],
    ])
    expect(changes).toEqual([])
    expect(workspace.focusedDestination.peek()).toEqual(chat("1"))
  })

  test("without an opener, newTab opens here", () => {
    const { workspace } = make({ initial: chat("1") })
    workspace.open(chat("2"), { intent: "newTab" })
    expect(workspace.focusedDestination.peek()).toEqual(chat("2"))
  })
})

describe("panes", () => {
  test("each pane keeps its own back and forward", () => {
    const { workspace } = make({ initial: chat("1") })
    workspace.open(chat("2"))
    workspace.open(chat("10"), { intent: "otherPane" })
    workspace.open(chat("11"))
    const [left, right] = workspace.panes.peek().map((p) => p.id)
    workspace.back(left)
    expect(shown(workspace)).toEqual([chat("1"), chat("11")])
    workspace.back(right)
    expect(shown(workspace)).toEqual([chat("1"), chat("10")])
    // Back with no pane named acts on the focused (right) pane.
    expect(workspace.back()).toBe(false)
    workspace.forward(left)
    expect(shown(workspace)).toEqual([chat("2"), chat("10")])
  })

  test("canGoBack follows the focused pane", () => {
    const { workspace } = make({ initial: chat("1") })
    workspace.open(chat("2"))
    workspace.open(chat("3"), { intent: "otherPane" })
    expect(workspace.canGoBack.peek()).toBe(false)
    workspace.focus(workspace.panes.peek()[0]?.id ?? "")
    expect(workspace.canGoBack.peek()).toBe(true)
  })

  test("closing the focused pane focuses its neighbor; the last pane stays", () => {
    const { workspace } = make({ initial: chat("1") })
    workspace.open(chat("2"), { intent: "otherPane" })
    expect(workspace.canClosePane.peek()).toBe(true)
    expect(workspace.closePane()).toBe(true)
    expect(shown(workspace)).toEqual([chat("1")])
    expect(workspace.focusedDestination.peek()).toEqual(chat("1"))
    expect(workspace.canClosePane.peek()).toBe(false)
    expect(workspace.closePane()).toBe(false)
  })

  test("focusAdjacent clamps at the edges", () => {
    const { workspace } = make({ initial: chat("1") })
    workspace.open(chat("2"), { intent: "otherPane" })
    expect(workspace.focusAdjacent(1)).toBe(false)
    expect(workspace.focusAdjacent(-1)).toBe(true)
    expect(workspace.focusedDestination.peek()).toEqual(chat("1"))
    expect(workspace.focusAdjacent(-1)).toBe(false)
  })
})

describe("view state", () => {
  test("survives navigating away and back", () => {
    const { workspace } = make()
    workspace.open(chat("1"))
    workspace.viewState.set(chat("1"), { anchor: "m9", offset: 12 })
    workspace.open(chat("2"))
    workspace.back()
    expect(workspace.viewState.get(workspace.focusedDestination.peek())).toEqual({ anchor: "m9", offset: 12 })
  })

  test("a chat, a message in it and a thread opened alone share the chat's state", () => {
    const { workspace } = make()
    workspace.viewState.set(chat("1"), "a")
    expect(workspace.viewState.get({ kind: "message", chatId: chatId("1"), messageId: messageId("2") })).toBe("a")
    workspace.viewState.set({ kind: "thread", parentChatId: chatId("1"), threadId: chatId("7") }, "t")
    expect(workspace.viewState.get(chat("7"))).toBe("t")
    expect(workspace.viewState.get({ kind: "chatInfo", chatId: chatId("1") })).toBeUndefined()
  })

  test("keeps the most recently used entries", () => {
    const { workspace } = make({ viewStateLimit: 2 })
    workspace.viewState.set(chat("1"), 1)
    workspace.viewState.set(chat("2"), 2)
    workspace.viewState.get(chat("1"))
    workspace.viewState.set(chat("3"), 3)
    expect(workspace.viewState.get(chat("2"))).toBeUndefined()
    expect(workspace.viewState.get(chat("1"))).toBe(1)
    expect(workspace.viewState.get(chat("3"))).toBe(3)
  })
})
