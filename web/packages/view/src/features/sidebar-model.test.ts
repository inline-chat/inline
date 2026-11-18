import { describe, expect, it } from "vitest"
import { effect } from "@inline/reactive"
import { message } from "@inline/reactive/testing"
import { Workspace } from "../workspace/workspace"
import { SidebarModel } from "./sidebar-model"
import { chatRow, cid, dialogRow, draftRow, harness, keys, uid, upserts, userRow } from "./test-support"

const setup = (options: { isFollowing?: (chatId: string) => boolean } = {}) => {
  const h = harness()
  const workspace = new Workspace({ createId: () => "w" })
  const sidebar = new SidebarModel({
    client: h.client,
    workspace,
    ...(options.isFollowing ? { hooks: { isFollowing: ({ dialog }) => options.isFollowing!(dialog.chatId) } } : {}),
  })
  const listSub = h.sub((query) => query.kind === "sidebar")
  return { ...h, workspace, sidebar, listSub }
}

// Chat 1: a DM with Ada. Chat 2: a titled thread. Chat 3: an untitled thread.
const ada = userRow(7, "Ada", { lastName: "Lovelace" })
const d1 = dialogRow(1, { peerUserId: uid(7), unreadCount: 2 })
const c1 = chatRow(1, { peerUserId: uid(7), lastMessageId: "11" as never, lastActivityDate: 1_700_000_011 })
const d2 = dialogRow(2, { unreadCount: 3, pinned: true })
const c2 = chatRow(2, { title: "  Launch  ", emoji: "🚀" })
const d3 = dialogRow(3, { unreadMark: true })
const c3 = chatRow(3)

const deliverSidebar = (s: ReturnType<typeof setup>) =>
  s.endpoint.patch({
    rows: upserts(ada, d1, c1, d2, c2, d3, c3),
    lists: [{ sub: s.listSub, op: "replace", keys: keys(d1, d2, d3) }],
  })

describe("SidebarModel", () => {
  it("subscribes to the sidebar query in inbox mode and keeps the core's order", async () => {
    const s = setup()
    expect(s.endpoint.commands("subscribe").map((c) => c.query)).toEqual([{ kind: "sidebar", mode: "inbox" }])
    deliverSidebar(s)
    await s.flush()
    expect(s.sidebar.items.peek()).toEqual(keys(d1, d2, d3))
  })

  it("derives title, avatar, unread, prominence and pinning per item", async () => {
    const s = setup()
    deliverSidebar(s)
    await s.flush()
    const [k1, k2, k3] = keys(d1, d2, d3)
    const dm = s.sidebar.item(k1!).peek()!
    expect(dm).toMatchObject({
      chatId: cid(1),
      peerUserId: uid(7),
      title: "Ada Lovelace",
      avatar: { kind: "user", userId: uid(7), seed: "Ada Lovelace" },
      unreadCount: 2,
      hasUnread: true,
      prominent: true,
      pinned: false,
      selected: false,
      date: 1_700_000_011,
      preview: { kind: "none" },
    })
    const thread = s.sidebar.item(k2!).peek()!
    expect(thread).toMatchObject({ title: "Launch", emoji: "🚀", prominent: false, pinned: true, hasUnread: true })
    expect(thread.avatar).toEqual({ kind: "chat", chatId: cid(2), seed: "Launch", emoji: "🚀" })
    const untitled = s.sidebar.item(k3!).peek()!
    expect(untitled).toMatchObject({ title: "New thread", hasUnread: true, unreadMark: true, prominent: false })
  })

  it("shows the last message, and a draft before it", async () => {
    const s = setup()
    deliverSidebar(s)
    await s.flush()
    const k1 = keys(d1)[0]!
    s.endpoint.patch({ rows: upserts(message(1, 11, "see you\n  tomorrow")) })
    await s.flush()
    expect(s.sidebar.item(k1).peek()!.preview).toEqual({ kind: "message", text: "see you tomorrow", outgoing: false })
    s.endpoint.patch({ rows: upserts(draftRow(1, "half a thought")) })
    await s.flush()
    expect(s.sidebar.item(k1).peek()!.preview).toEqual({ kind: "draft", text: "half a thought" })
    // An emptied draft gives the message back.
    s.endpoint.patch({ rows: upserts(draftRow(1, "   ", 2)) })
    await s.flush()
    expect(s.sidebar.item(k1).peek()!.preview.kind).toBe("message")
  })

  it("marks the chat shown in the focused pane as selected", async () => {
    const s = setup()
    deliverSidebar(s)
    await s.flush()
    const [k1, k2] = keys(d1, d2)
    s.sidebar.open(k2!)
    expect(s.workspace.focusedDestination.peek()).toEqual({ kind: "chat", chatId: cid(2) })
    expect(s.sidebar.item(k2!).peek()!.selected).toBe(true)
    expect(s.sidebar.item(k1!).peek()!.selected).toBe(false)
    s.workspace.open({ kind: "message", chatId: cid(1), messageId: "5" as never })
    expect(s.sidebar.item(k1!).peek()!.selected).toBe(true)
    expect(s.sidebar.item(k2!).peek()!.selected).toBe(false)
  })

  it("a change to one chat notifies only that item, and a reorder notifies none", async () => {
    const s = setup()
    deliverSidebar(s)
    await s.flush()
    const [k1, k2, k3] = keys(d1, d2, d3)
    const runs = { a: 0, b: 0, c: 0, list: 0 }
    const stops = [
      effect(() => {
        s.sidebar.item(k1!).get()
        runs.a += 1
      }),
      effect(() => {
        s.sidebar.item(k2!).get()
        runs.b += 1
      }),
      effect(() => {
        s.sidebar.item(k3!).get()
        runs.c += 1
      }),
      effect(() => {
        s.sidebar.items.get()
        runs.list += 1
      }),
    ]
    expect(runs).toEqual({ a: 1, b: 1, c: 1, list: 1 })

    s.endpoint.patch({ rows: upserts({ ...d2, unreadCount: 4 }) })
    await s.flush()
    expect(runs).toEqual({ a: 1, b: 2, c: 1, list: 1 })

    // Same values in a new object: nothing changes.
    s.endpoint.patch({ rows: upserts({ ...c1 }) })
    await s.flush()
    expect(runs).toEqual({ a: 1, b: 2, c: 1, list: 1 })

    s.endpoint.patch({ lists: [{ sub: s.listSub, op: "replace", keys: keys(d3, d1, d2) }] })
    await s.flush()
    expect(runs).toEqual({ a: 1, b: 2, c: 1, list: 2 })

    // Selecting a chat changes two items, not all of them.
    s.sidebar.open(k3!)
    expect(runs).toEqual({ a: 1, b: 2, c: 2, list: 2 })
    for (const stop of stops) stop()
  })

  it("selects the next and previous chat in the core's order and stops at the ends", async () => {
    const s = setup()
    expect(s.sidebar.canSelectAdjacent.peek()).toBe(false)
    expect(s.sidebar.selectAdjacent(1)).toBe(false)
    deliverSidebar(s)
    await s.flush()
    expect(s.sidebar.canSelectAdjacent.peek()).toBe(true)
    const shown = () => s.workspace.focusedDestination.peek()
    expect(s.sidebar.selectAdjacent(1)).toBe(true)
    expect(shown()).toEqual({ kind: "chat", chatId: cid(1) })
    s.sidebar.selectAdjacent(1)
    expect(shown()).toEqual({ kind: "chat", chatId: cid(2) })
    s.sidebar.selectAdjacent(1)
    expect(shown()).toEqual({ kind: "chat", chatId: cid(3) })
    expect(s.sidebar.selectAdjacent(1)).toBe(false)
    expect(shown()).toEqual({ kind: "chat", chatId: cid(3) })
    s.sidebar.selectAdjacent(-1)
    expect(shown()).toEqual({ kind: "chat", chatId: cid(2) })
    // With nothing selected, previous starts from the end.
    s.workspace.open({ kind: "settings" })
    s.sidebar.selectAdjacent(-1)
    expect(shown()).toEqual({ kind: "chat", chatId: cid(3) })
  })

  it("counts prominent unread chats for the badge", async () => {
    const s = setup()
    deliverSidebar(s)
    await s.flush()
    // Only the DM is prominent; the threads' unread is muted.
    expect(s.sidebar.prominentUnreadCount.peek()).toBe(1)
    s.endpoint.patch({ rows: upserts({ ...d1, unreadCount: 0 }) })
    await s.flush()
    expect(s.sidebar.prominentUnreadCount.peek()).toBe(0)

    const followed = setup({ isFollowing: (chatId) => chatId === cid(2) })
    deliverSidebar(followed)
    await followed.flush()
    expect(followed.sidebar.prominentUnreadCount.peek()).toBe(2)
  })

  it("switches mode by subscribing to the new list and dropping the old", async () => {
    const s = setup()
    deliverSidebar(s)
    await s.flush()
    s.sidebar.setMode("all")
    expect(s.sidebar.mode.peek()).toBe("all")
    expect(s.openSubs()).toEqual([{ kind: "sidebar", mode: "all" }])
    const sub = s.sub((query) => query.kind === "sidebar")
    s.endpoint.patch({ lists: [{ sub, op: "replace", keys: keys(d3) }] })
    await s.flush()
    expect(s.sidebar.items.peek()).toEqual(keys(d3))
    s.sidebar.dispose()
    expect(s.openSubs()).toEqual([])
  })
})
