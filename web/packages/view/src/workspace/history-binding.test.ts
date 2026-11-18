import { chatId } from "@inline/ids"
import { describe, expect, test } from "vitest"
import type { Destination } from "./destination"
import { createMemoryHistory, type MemoryHistory } from "./history"
import { bindWorkspaceToHistory, readStamp } from "./history-binding"
import { restoreWorkspace, serializeWorkspace } from "./persistence"
import { Workspace } from "./workspace"

const chat = (id: string): Destination => ({ kind: "chat", chatId: chatId(id) })

const setup = (path = "/", workspace = new Workspace({ createId: () => "ws" })) => {
  const history = createMemoryHistory(path)
  let clock = 1000
  const binding = bindWorkspaceToHistory(workspace, history, { now: () => clock++ })
  return { workspace, history, binding }
}

const paths = (history: MemoryHistory) => history.entries().map((e) => e.path)
const shown = (workspace: Workspace) => workspace.panes.peek().map((p) => workspace.destination(p.id))
const [left, right] = [0, 1]
const paneId = (workspace: Workspace, index: number) => workspace.panes.peek()[index]?.id ?? ""

describe("address bar mirrors the focused pane", () => {
  test("first load at / stamps the entry without adding one", () => {
    const { history, workspace } = setup("/")
    expect(paths(history)).toEqual(["/"])
    const stamp = readStamp(history.current().state)
    expect(stamp).toMatchObject({ ws: "ws", pane: workspace.focusedPaneId.peek() })
  })

  test("first load at a chat URL opens it in the focused pane", () => {
    const restored = new Workspace({ createId: () => "ws", initial: chat("1") })
    const { history, workspace } = setup("/c/5", restored)
    expect(workspace.focusedDestination.peek()).toEqual(chat("5"))
    // The pane can go back to what was restored; the browser has one entry.
    expect(workspace.canGoBack.peek()).toBe(true)
    expect(paths(history)).toEqual(["/c/5"])
  })

  test("first load at / or a broken URL keeps the restored workspace and shows its URL", () => {
    for (const path of ["/", "/nope", "/c/abc"]) {
      const restored = new Workspace({ createId: () => "ws", initial: chat("1") })
      const { history, workspace } = setup(path, restored)
      expect(workspace.focusedDestination.peek()).toEqual(chat("1"))
      expect(paths(history)).toEqual(["/c/1"])
    }
  })

  test("each navigation of the focused pane adds one entry; replace adds none", () => {
    const { history, workspace } = setup()
    workspace.open(chat("1"))
    workspace.open(chat("2"))
    workspace.replace({ kind: "message", chatId: chatId("2"), messageId: "9" as never })
    expect(paths(history)).toEqual(["/", "/c/1", "/c/2/m/9"])
  })

  test("navigating a pane that is not focused leaves the address bar alone", () => {
    const { history, workspace } = setup()
    workspace.open(chat("1"))
    workspace.open(chat("2"), { intent: "otherPane", focus: false })
    workspace.openInPane(paneId(workspace, right), chat("3"), { focus: false })
    expect(paths(history)).toEqual(["/", "/c/1"])
    expect(history.current().path).toBe("/c/1")
  })

  test("focusing another pane replaces the entry; it does not add one", () => {
    const { history, workspace } = setup()
    workspace.open(chat("1"))
    workspace.open(chat("2"), { intent: "otherPane" })
    expect(paths(history)).toEqual(["/", "/c/1", "/c/2"])
    workspace.focus(paneId(workspace, left))
    expect(paths(history)).toEqual(["/", "/c/1", "/c/1"])
    workspace.closePane(paneId(workspace, right))
    expect(paths(history)).toEqual(["/", "/c/1", "/c/1"])
  })
})

describe("browser Back and Forward", () => {
  test("with one pane they are exactly the pane's back and forward", () => {
    const { history, workspace } = setup()
    for (const id of ["1", "2", "3"]) workspace.open(chat(id))
    history.back()
    expect(workspace.focusedDestination.peek()).toEqual(chat("2"))
    history.back()
    history.back()
    expect(workspace.focusedDestination.peek()).toEqual({ kind: "empty" })
    expect(workspace.canGoBack.peek()).toBe(false)
    history.forward()
    expect(workspace.focusedDestination.peek()).toEqual(chat("1"))
    // A new navigation drops forward entries in both.
    workspace.open(chat("9"))
    expect(paths(history)).toEqual(["/", "/c/1", "/c/9"])
    expect(workspace.canGoForward.peek()).toBe(false)
    expect(workspace.focusedPane.peek().entries.map((e) => e.destination)).toEqual([
      { kind: "empty" },
      chat("1"),
      chat("9"),
    ])
  })

  test("the app adds no entries the user did not cause", () => {
    const { history, workspace } = setup()
    workspace.open(chat("1"))
    history.back()
    history.forward()
    workspace.focus(paneId(workspace, left))
    expect(paths(history)).toEqual(["/", "/c/1"])
  })

  test("across panes they walk visits in order and focus the pane that moves", () => {
    const { history, workspace } = setup()
    workspace.open(chat("1"))
    workspace.open(chat("2"))
    workspace.open(chat("10"), { intent: "otherPane" })
    workspace.open(chat("11"))
    expect(paths(history)).toEqual(["/", "/c/1", "/c/2", "/c/10", "/c/11"])

    history.back()
    expect(shown(workspace)).toEqual([chat("2"), chat("10")])
    expect(workspace.focusedPaneId.peek()).toBe(paneId(workspace, right))

    history.back()
    expect(shown(workspace)).toEqual([chat("2"), chat("10")])
    expect(workspace.focusedPaneId.peek()).toBe(paneId(workspace, left))

    history.back()
    expect(shown(workspace)).toEqual([chat("1"), chat("10")])

    history.forward()
    history.forward()
    expect(shown(workspace)).toEqual([chat("2"), chat("10")])
    expect(workspace.focusedPaneId.peek()).toBe(paneId(workspace, right))
    history.forward()
    expect(shown(workspace)).toEqual([chat("2"), chat("11")])
  })

  test("an entry whose pane was closed opens its URL in the focused pane", () => {
    const { history, workspace } = setup()
    workspace.open(chat("1"))
    workspace.open(chat("10"), { intent: "otherPane" })
    workspace.open(chat("11"))
    workspace.focus(paneId(workspace, left))
    workspace.closePane(paneId(workspace, right))
    expect(paths(history)).toEqual(["/", "/c/1", "/c/10", "/c/1"])
    history.back()
    expect(shown(workspace)).toEqual([chat("10")])
    expect(workspace.focusedPane.peek().entries.map((e) => e.destination)).toEqual([
      { kind: "empty" },
      chat("1"),
      chat("10"),
    ])
    // The entry now belongs to the surviving pane.
    expect(readStamp(history.current().state)).toMatchObject({
      pane: paneId(workspace, left),
      entry: workspace.currentEntry()?.id,
    })
  })

  test("an entry that fell off the history cap reopens its URL in its pane", () => {
    const workspace = new Workspace({ createId: () => "ws", historyLimit: 2 })
    const { history } = setup("/", workspace)
    for (const id of ["1", "2", "3"]) workspace.open(chat(id))
    history.go(-2)
    expect(workspace.focusedDestination.peek()).toEqual(chat("1"))
    expect(readStamp(history.current().state)?.entry).toBe(workspace.currentEntry()?.id)
  })

  test("an entry the app did not make opens its URL in the focused pane", () => {
    const { history, workspace } = setup()
    workspace.open(chat("1"))
    history.push("/c/7", { inline: { ws: "another-session", pane: "p1", entry: "e1", seq: 1 } })
    history.push("/c/8", null)
    history.back()
    expect(workspace.focusedDestination.peek()).toEqual(chat("7"))
    expect(readStamp(history.current().state)?.ws).toBe("ws")
  })
})

describe("in-app Back and Forward", () => {
  test("move the browser too while the two are in step", () => {
    const { history, workspace, binding } = setup()
    workspace.open(chat("1"))
    workspace.open(chat("2"))
    expect(binding.back()).toBe(true)
    expect(history.index()).toBe(1)
    expect(workspace.focusedDestination.peek()).toEqual(chat("1"))
    expect(binding.forward()).toBe(true)
    expect(history.index()).toBe(2)
    expect(workspace.focusedDestination.peek()).toEqual(chat("2"))
  })

  test("act on the focused pane only, replacing the entry when out of step", () => {
    const { history, workspace, binding } = setup()
    workspace.open(chat("1"))
    workspace.open(chat("2"))
    workspace.open(chat("10"), { intent: "otherPane" })
    workspace.focus(paneId(workspace, left))
    // Focusing replaced the current entry with the left pane's /c/2, so the
    // previous browser entry (also /c/2) is not the pane's previous entry.
    expect(binding.back()).toBe(true)
    expect(shown(workspace)).toEqual([chat("1"), chat("10")])
    expect(binding.back()).toBe(true)
    expect(shown(workspace)).toEqual([{ kind: "empty" }, chat("10")])
    expect(binding.back()).toBe(false)
    expect(history.current().path).toBe("/")
  })

  test("do nothing at the ends", () => {
    const { binding } = setup()
    expect(binding.back()).toBe(false)
    expect(binding.forward()).toBe(false)
  })
})

describe("reload", () => {
  test("restored workspace and surviving browser entries stay in step", () => {
    const first = setup()
    first.workspace.open(chat("1"))
    first.workspace.open(chat("2"))
    first.workspace.open(chat("10"), { intent: "otherPane" })
    first.history.back()
    const saved = serializeWorkspace(first.workspace)
    first.binding.dispose()

    // Same session history, new page: the workspace comes back from storage.
    const workspace = restoreWorkspace(saved)
    bindWorkspaceToHistory(workspace, first.history)
    expect(shown(workspace)).toEqual([chat("2"), chat("10")])
    expect(workspace.focusedPaneId.peek()).toBe(paneId(workspace, left))
    first.history.back()
    expect(shown(workspace)).toEqual([chat("1"), chat("10")])
    first.history.forward()
    first.history.forward()
    expect(workspace.focusedPaneId.peek()).toBe(paneId(workspace, right))
  })

  test("dispose stops both directions", () => {
    const { history, workspace, binding } = setup()
    binding.dispose()
    workspace.open(chat("1"))
    expect(paths(history)).toEqual(["/"])
    history.push("/c/2", null)
    history.push("/c/3", null)
    history.back()
    expect(workspace.focusedDestination.peek()).toEqual(chat("1"))
  })
})
