import { chatId } from "@inline/ids"
import { describe, expect, test } from "vitest"
import type { Destination } from "./destination"
import {
  createWorkspaceStore,
  parseWorkspaceSnapshot,
  restoreWorkspace,
  serializeWorkspace,
  type StorageLike,
} from "./persistence"
import { Workspace } from "./workspace"

const chat = (id: string): Destination => ({ kind: "chat", chatId: chatId(id) })

const twoPaneWorkspace = () => {
  const workspace = new Workspace({ createId: () => "ws-1", initial: chat("1") })
  workspace.open(chat("2"))
  workspace.open({ kind: "settings", page: "appearance" })
  workspace.back()
  workspace.open({ kind: "thread", parentChatId: chatId("2"), threadId: chatId("9") }, { intent: "otherPane" })
  workspace.open({ kind: "search", query: "budget" })
  workspace.viewState.set(chat("2"), { anchor: "42", offset: -8 })
  return workspace
}

describe("round trip", () => {
  test("restores panes, histories, positions, focus, IDs and view state", () => {
    const original = twoPaneWorkspace()
    const restored = restoreWorkspace(serializeWorkspace(original))
    expect(restored.state.peek()).toEqual(original.state.peek())
    expect(restored.viewState.get(chat("2"))).toEqual({ anchor: "42", offset: -8 })
    // Navigation keeps working, and new IDs do not collide with restored ones.
    restored.back()
    expect(restored.focusedDestination.peek()).toEqual({ kind: "thread", parentChatId: "2", threadId: "9" })
    const before = new Set(restored.panes.peek().flatMap((p) => p.entries.map((e) => e.id)))
    const result = restored.open(chat("5"))
    expect(result.kind === "pane" && !before.has(result.entryId)).toBe(true)
  })

  test("leaves out sign-in and join flows, keeping the pane where it was", () => {
    const workspace = new Workspace({ createId: () => "ws", initial: chat("1") })
    workspace.open({ kind: "invite", token: `iv1_${"a".repeat(43)}` })
    workspace.open(chat("2"))
    workspace.open({ kind: "signIn" })
    const restored = restoreWorkspace(serializeWorkspace(workspace))
    const pane = restored.focusedPane.peek()
    expect(pane.entries.map((e) => e.destination)).toEqual([chat("1"), chat("2")])
    expect(restored.focusedDestination.peek()).toEqual(chat("2"))
  })

  test("a pane with only transient entries restores as empty", () => {
    const workspace = new Workspace({ createId: () => "ws", initial: { kind: "signIn" } })
    const restored = restoreWorkspace(serializeWorkspace(workspace))
    expect(restored.focusedDestination.peek()).toEqual({ kind: "empty" })
  })

  test("view state that is not JSON is not written", () => {
    const workspace = new Workspace({ createId: () => "ws" })
    workspace.viewState.set(chat("1"), { ok: true })
    workspace.viewState.set(chat("2"), 10n)
    const restored = restoreWorkspace(serializeWorkspace(workspace))
    expect(restored.viewState.get(chat("1"))).toEqual({ ok: true })
    expect(restored.viewState.get(chat("2"))).toBeUndefined()
  })
})

describe("older and damaged snapshots", () => {
  test("a version 0 snapshot (one history, no panes) restores into one pane", () => {
    const v0 = JSON.stringify({ history: ["/chats", "/c/12", "/nope", "/c/12/m/3", "/settings"], historyIndex: 3 })
    const restored = restoreWorkspace(v0, { createId: () => "fresh" })
    const state = restored.state.peek()
    expect(state.id).toBe("fresh")
    expect(state.panes).toHaveLength(1)
    expect(restored.focusedPane.peek().entries.map((e) => e.destination)).toEqual([
      { kind: "allChats" },
      chat("12"),
      { kind: "message", chatId: "12", messageId: "3" },
      { kind: "settings" },
    ])
    // Index 3 pointed at /c/12/m/3; the dropped /nope entry before it shifts it to 2.
    expect(restored.focusedDestination.peek()).toEqual({ kind: "message", chatId: "12", messageId: "3" })
    expect(restored.canGoForward.peek()).toBe(true)
  })

  test("a newer version is ignored rather than guessed at", () => {
    expect(parseWorkspaceSnapshot(JSON.stringify({ v: 2, panes: [] }))).toBeUndefined()
    expect(restoreWorkspace(JSON.stringify({ v: 2 }), { initial: chat("1") }).focusedDestination.peek()).toEqual(
      chat("1"),
    )
  })

  test.each([null, undefined, "", "{", "[]", "42", "null", JSON.stringify({ v: "1" })])(
    "%j starts fresh",
    (raw) => {
      expect(parseWorkspaceSnapshot(raw as string)).toBeUndefined()
      expect(() => restoreWorkspace(raw as string)).not.toThrow()
    },
  )

  test("bad panes, entries and indexes are repaired", () => {
    const raw = JSON.stringify({
      v: 1,
      id: "ws",
      nextId: "x",
      focused: "p404",
      panes: [
        "junk",
        { id: "p1", index: 99, entries: [["e1", "/c/1"], ["e1", "/c/2"], "junk", ["e3", 5], ["e4", "/nope"]] },
        { id: "p1", index: -3, entries: [[7, "/c/3"]] },
        { id: "p9", index: 0, entries: [] },
      ],
      viewState: [["chat:1", { a: 1 }], "junk", [1, 2]],
    })
    const restored = restoreWorkspace(raw)
    const state = restored.state.peek()
    expect(state.panes).toHaveLength(2)
    const [first, second] = state.panes
    expect(first?.entries.map((e) => e.destination)).toEqual([chat("1"), chat("2")])
    expect(first?.index).toBe(1)
    expect(second?.entries.map((e) => e.destination)).toEqual([chat("3")])
    expect(second?.index).toBe(0)
    const ids = state.panes.flatMap((p) => [p.id, ...p.entries.map((e) => e.id)])
    expect(new Set(ids).size).toBe(ids.length)
    expect(state.focusedPaneId).toBe(first?.id)
    const highest = Math.max(...ids.map((id) => Number(id.slice(1))))
    expect(state.nextId).toBeGreaterThan(highest)
    expect(restored.viewState.get(chat("1"))).toEqual({ a: 1 })
  })

  test("a restored history longer than the cap keeps the newest entries", () => {
    const history = Array.from({ length: 10 }, (_, i) => `/c/${i + 1}`)
    const restored = restoreWorkspace(JSON.stringify({ history, historyIndex: 9 }), { historyLimit: 4 })
    expect(restored.focusedPane.peek().entries.map((e) => e.destination)).toEqual([
      chat("7"),
      chat("8"),
      chat("9"),
      chat("10"),
    ])
    expect(restored.focusedDestination.peek()).toEqual(chat("10"))
  })
})

describe("store", () => {
  const memoryStorage = (): StorageLike & { data: Map<string, string> } => {
    const data = new Map<string, string>()
    return {
      data,
      getItem: (key) => data.get(key) ?? null,
      setItem: (key, value) => void data.set(key, value),
      removeItem: (key) => void data.delete(key),
    }
  }

  test("saves and loads under its key", () => {
    const storage = memoryStorage()
    const store = createWorkspaceStore(storage, "inline.workspace.u1")
    const workspace = twoPaneWorkspace()
    store.save(workspace)
    expect(restoreWorkspace(store.load()).state.peek()).toEqual(workspace.state.peek())
    store.clear()
    expect(store.load()).toBeNull()
  })

  test("storage failures are swallowed", () => {
    const failing: StorageLike = {
      getItem: () => {
        throw new Error("SecurityError")
      },
      setItem: () => {
        throw new Error("QuotaExceededError")
      },
      removeItem: () => {
        throw new Error("SecurityError")
      },
    }
    const store = createWorkspaceStore(failing, "k")
    expect(store.load()).toBeNull()
    expect(() => store.save(new Workspace())).not.toThrow()
    expect(() => store.clear()).not.toThrow()
  })
})
