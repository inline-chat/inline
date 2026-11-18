import { describe, expect, it } from "vitest"
import type { MessageRow } from "@inline/core-protocol"
import { sentMessageRowId } from "@inline/core-protocol"
import { effect } from "@inline/reactive"
import { message } from "@inline/reactive/testing"
import { Workspace } from "../workspace/workspace"
import { messagePreviewSource, SidebarModel } from "./sidebar-model"
import { chatRow, cid, dialogRow, draftRow, harness, keys, mid, uid, upserts, userRow } from "./test-support"

/** A sidebar model as the session builds it: with the core endpoint, so it knows when a list was answered. */
const setup = (options: { mode?: "inbox" | "all"; followCalls?: Map<string, number> } = {}) => {
  const h = harness()
  const workspace = new Workspace({ createId: () => "w" })
  const calls = options.followCalls
  const sidebar = new SidebarModel({
    client: h.client,
    workspace,
    core: h.endpoint,
    ...(options.mode ? { mode: options.mode } : {}),
    ...(calls
      ? {
          hooks: {
            isFollowing: ({ dialog }) => {
              calls.set(dialog.chatId, (calls.get(dialog.chatId) ?? 0) + 1)
              return false
            },
          },
        }
      : {}),
  })
  const listSub = () => h.sub((query) => query.kind === "sidebar")
  return { ...h, workspace, sidebar, listSub }
}

const ada = userRow(7, "Ada", { lastName: "Lovelace" })
const grace = userRow(8, "Grace", { lastName: "Hopper" })
// Chat 1: a DM with Ada. Chat 2: a thread whose last message is Grace's. Chat 3: a followed thread.
const d1 = dialogRow(1, { peerUserId: uid(7), unreadCount: 2, unreadMentionsCount: 1 })
const c1 = chatRow(1, { peerUserId: uid(7), lastMessageId: mid(11) })
const m1 = message(1, 11, "see you", { fromId: uid(7) })
const d2 = dialogRow(2, { unreadCount: 3, unreadReactionsCount: 2, notificationMode: "mentions" })
const c2 = chatRow(2, { title: "Launch", lastMessageId: mid(21) })
const m2 = message(2, 21, "shipping today", { fromId: uid(8) })
const d3 = dialogRow(3, { unreadCount: 1, followMode: "following" })
const c3 = chatRow(3, { title: "Design" })

const deliver = (s: ReturnType<typeof setup>, sub = s.listSub()) =>
  s.endpoint.patch({
    rows: upserts(ada, grace, d1, c1, m1, d2, c2, m2, d3, c3),
    lists: [{ sub, op: "replace", keys: keys(d1, d2, d3) }],
  })

describe("SidebarModel on full sidebar rows", () => {
  it("previews the last message of every chat, with the sender's short name in threads", async () => {
    const s = setup()
    deliver(s)
    await s.flush()
    const [k1, k2] = keys(d1, d2)
    expect(s.sidebar.item(k1!).peek()!.preview).toEqual({ kind: "message", text: "see you", outgoing: false })
    expect(s.sidebar.item(k2!).peek()!.preview).toEqual({
      kind: "message",
      text: "shipping today",
      outgoing: false,
      sender: "Grace",
    })
    // A draft still comes first.
    s.endpoint.patch({ rows: upserts(draftRow(2, "wait")) })
    await s.flush()
    expect(s.sidebar.item(k2!).peek()!.preview).toEqual({ kind: "draft", text: "wait" })
  })

  it("finds a last message sent from this device by its row ID", async () => {
    const s = setup()
    deliver(s)
    await s.flush()
    const own: MessageRow = {
      kind: "message",
      id: sentMessageRowId(cid(2), "55"),
      chatId: cid(2),
      clientKey: "55",
      fromId: uid(1),
      out: true,
      date: 1_800_000_000,
      text: "on it",
      state: "sending",
    }
    s.endpoint.patch({
      rows: upserts(own, userRow(1, "Mo"), { ...c2, lastMessageRowId: own.id }),
    })
    await s.flush()
    expect(s.sidebar.item(keys(d2)[0]!).peek()!.preview).toEqual({ kind: "message", text: "on it", outgoing: true, sender: "Mo" })
  })

  it("names media and documents when a message has no text", () => {
    const photo = message(1, 1, "", { media: { kind: "photo", photo: { id: "1" as never, sizes: [] } } })
    expect(messagePreviewSource(photo)).toBe("Photo")
    const doc = message(1, 1, "notes", { media: { kind: "document", document: { id: "1" as never, fileName: "Q3.pdf", mimeType: "application/pdf", size: 1 } } })
    expect(messagePreviewSource(doc)).toBe("\u{1F4C4} Q3.pdf")
    expect(messagePreviewSource(message(1, 1, ""))).toBe("Message")
  })

  it("makes a followed thread's unread prominent, as a DM's", async () => {
    const s = setup()
    deliver(s)
    await s.flush()
    const [k1, k2, k3] = keys(d1, d2, d3)
    expect(s.sidebar.item(k1!).peek()!.prominent).toBe(true)
    expect(s.sidebar.item(k2!).peek()!.prominent).toBe(false)
    expect(s.sidebar.item(k3!).peek()!).toMatchObject({ prominent: true, followMode: "following" })
    expect(s.sidebar.prominentUnreadKeys.peek()).toEqual([k1, k3])
    expect(s.sidebar.prominentUnread.peek().indices).toEqual([0, 2])
    expect(s.sidebar.prominentUnreadCount.peek()).toBe(2)
    // Unfollowing makes it muted.
    s.endpoint.patch({ rows: upserts({ ...d3, followMode: "unfollowed" }) })
    await s.flush()
    expect(s.sidebar.prominentUnreadKeys.peek()).toEqual([k1])
  })

  it("carries mention and reaction counts, modes, open and archived, and temporary rows", async () => {
    const s = setup()
    deliver(s)
    await s.flush()
    const [k1, k2] = keys(d1, d2)
    expect(s.sidebar.item(k1!).peek()!).toMatchObject({ unreadMentionCount: 1, unreadReactionCount: 0, open: true, archived: false, temporary: false })
    expect(s.sidebar.item(k2!).peek()!).toMatchObject({ unreadReactionCount: 2, notificationMode: "mentions" })
    // The selected chat shown though it is not open (rule 7).
    s.endpoint.patch({ rows: upserts({ ...d2, open: false }) })
    await s.flush()
    expect(s.sidebar.item(k2!).peek()!).toMatchObject({ open: false, temporary: true })
    s.endpoint.patch({ rows: upserts({ ...d2, open: false, pinned: true }) })
    await s.flush()
    expect(s.sidebar.item(k2!).peek()!.temporary).toBe(false)
  })

  it("the prominent unread list does not depend on the selection", async () => {
    const s = setup()
    deliver(s)
    await s.flush()
    let runs = 0
    const stop = effect(() => {
      s.sidebar.prominentUnread.get()
      runs += 1
    })
    s.sidebar.open(keys(d2)[0]!)
    s.sidebar.open(keys(d3)[0]!)
    expect(runs).toBe(1)
    s.endpoint.patch({ rows: upserts({ ...d1, unreadCount: 0 }) })
    await s.flush()
    expect(runs).toBe(2)
    expect(s.sidebar.prominentUnreadKeys.peek()).toEqual(keys(d3))
    stop()
  })

  it("one chat changing re-runs that chat's derivations only, and a reorder none", async () => {
    const calls = new Map<string, number>()
    const s = setup({ followCalls: calls })
    deliver(s)
    await s.flush()
    const stops = keys(d1, d2, d3).map((key) => effect(() => void s.sidebar.item(key).get()))
    stops.push(effect(() => void s.sidebar.prominentUnreadCount.get()))
    const before = new Map(calls)
    expect(before.get(cid(2))).toBeGreaterThan(0)

    s.endpoint.patch({ rows: upserts({ ...d2, unreadCount: 4 }) })
    await s.flush()
    expect(calls.get(cid(2))).toBeGreaterThan(before.get(cid(2))!)
    expect(calls.get(cid(1))).toBe(before.get(cid(1)))
    expect(calls.get(cid(3))).toBe(before.get(cid(3)))

    const afterChange = new Map(calls)
    s.endpoint.patch({ lists: [{ sub: s.listSub(), op: "replace", keys: keys(d3, d1, d2) }] })
    await s.flush()
    expect(calls).toEqual(afterChange)
    expect(s.sidebar.prominentUnread.peek().indices).toEqual([0, 1])
    for (const stop of stops) stop()
  })
})

describe("SidebarModel ready and mode switches", () => {
  it("is not ready until the core answers, even with an empty list", async () => {
    const s = setup()
    expect(s.sidebar.ready.peek()).toBe(false)
    s.endpoint.patch({ lists: [{ sub: s.listSub(), op: "replace", keys: [] }] })
    // Delivered, not yet applied: still not ready.
    expect(s.sidebar.ready.peek()).toBe(false)
    await s.flush()
    expect(s.sidebar.ready.peek()).toBe(true)
    expect(s.sidebar.items.peek()).toEqual([])
  })

  it("is ready from a snapshot that names its list", async () => {
    const s = setup()
    s.endpoint.deliver({
      kind: "snapshot",
      snapshot: { revision: 3, rows: [d1, c1], lists: [{ sub: s.listSub(), keys: keys(d1) }], resources: [] },
    })
    await s.flush()
    expect(s.sidebar.ready.peek()).toBe(true)
    expect(s.sidebar.items.peek()).toEqual(keys(d1))
  })

  it("holds the previous list across a mode switch until the new one is answered", async () => {
    const s = setup()
    deliver(s)
    await s.flush()
    const inboxSub = s.listSub()
    let listRuns = 0
    const stop = effect(() => {
      s.sidebar.items.get()
      listRuns += 1
    })

    s.sidebar.setMode("all")
    expect(s.sidebar.mode.peek()).toBe("all")
    expect(s.sidebar.ready.peek()).toBe(false)
    expect(s.sidebar.items.peek()).toEqual(keys(d1, d2, d3))
    // Both stay subscribed while the old list is on screen.
    expect(s.openSubs()).toEqual([
      { kind: "sidebar", mode: "inbox" },
      { kind: "sidebar", mode: "all" },
    ])
    const allSub = s.sub((query) => query.kind === "sidebar" && query.mode === "all")
    // An unrelated patch does not release the hold.
    s.endpoint.patch({ rows: upserts({ ...d1, unreadCount: 5 }) })
    await s.flush()
    expect(s.sidebar.items.peek()).toEqual(keys(d1, d2, d3))
    expect(listRuns).toBe(1)

    s.endpoint.patch({ lists: [{ sub: allSub, op: "replace", keys: keys(d2) }] })
    await s.flush()
    expect(s.sidebar.ready.peek()).toBe(true)
    expect(s.sidebar.items.peek()).toEqual(keys(d2))
    expect(listRuns).toBe(2)
    expect(s.openSubs()).toEqual([{ kind: "sidebar", mode: "all" }])
    expect(inboxSub).not.toBe(allSub)
    stop()
  })

  it("an empty answer releases the hold too", async () => {
    const s = setup()
    deliver(s)
    await s.flush()
    s.sidebar.setMode("archived")
    const archivedSub = s.sub((query) => query.kind === "sidebar" && query.mode === "archived")
    s.endpoint.patch({ lists: [{ sub: archivedSub, op: "replace", keys: [] }] })
    await s.flush()
    expect(s.sidebar.ready.peek()).toBe(true)
    expect(s.sidebar.items.peek()).toEqual([])
    expect(s.openSubs()).toEqual([{ kind: "sidebar", mode: "archived" }])
  })

  it("switching again before the answer keeps the first list, and switching back takes it up", async () => {
    const s = setup()
    deliver(s)
    await s.flush()
    s.sidebar.setMode("all")
    s.sidebar.setMode("archived")
    expect(s.openSubs()).toEqual([
      { kind: "sidebar", mode: "inbox" },
      { kind: "sidebar", mode: "archived" },
    ])
    expect(s.sidebar.items.peek()).toEqual(keys(d1, d2, d3))
    s.sidebar.setMode("inbox")
    expect(s.openSubs()).toEqual([{ kind: "sidebar", mode: "inbox" }])
    expect(s.sidebar.ready.peek()).toBe(true)
    expect(s.sidebar.items.peek()).toEqual(keys(d1, d2, d3))
    s.sidebar.dispose()
    expect(s.openSubs()).toEqual([])
  })

  it("disposing while holding releases both lists", async () => {
    const s = setup()
    deliver(s)
    await s.flush()
    s.sidebar.setMode("all")
    s.sidebar.dispose()
    expect(s.openSubs()).toEqual([])
  })
})
