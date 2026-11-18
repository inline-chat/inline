import { describe, expect, it } from "vitest"
import { receivedMessageRowId, rowKeyOf, type MessageRow, type Row } from "@inline/core-protocol"
import { effect, type ClientSnapshotData } from "@inline/reactive"
import { AccountSession, relatedRowKeys } from "./account-session"
import type { SidebarItem } from "./sidebar-model"
import {
  chatRow,
  cid,
  coreResource,
  dialogRow,
  draftRow,
  harness,
  keys,
  mid,
  uid,
  upserts,
  userRow,
  windowResource,
  type Harness,
} from "./test-support"

const message = (chat: number, id: number, from = 2): MessageRow => ({
  kind: "message",
  id: receivedMessageRowId(cid(chat), mid(id)),
  chatId: cid(chat),
  messageId: mid(id),
  fromId: uid(from),
  out: from === 1,
  date: 1_700_000_000 + id,
  text: `message ${id}`,
  state: "sent",
})

/** One account's data: two DMs with last messages, a draft, the user. */
const world = () => {
  const me = userRow(1, "Me")
  const peers = [userRow(2, "Ada"), userRow(3, "Grace")]
  const chats = [chatRow(10, { peerUserId: uid(2), lastMessageId: mid(3) }), chatRow(11, { peerUserId: uid(3), lastMessageId: mid(9) })]
  const dialogs = [dialogRow(10, { peerUserId: uid(2), unreadCount: 1 }), dialogRow(11, { peerUserId: uid(3) })]
  const messages = [message(10, 1, 1), message(10, 2), message(10, 3)]
  const last11 = message(11, 9, 3)
  const draft = draftRow(10, "half a thought")
  return { me, peers, chats, dialogs, messages, last11, draft }
}

const session = (h: Harness, provisional?: ClientSnapshotData) =>
  new AccountSession({
    userId: uid(1),
    token: "secret",
    clock: h.time,
    residentChats: 1,
    connect: () => ({ ...h.connection(), ...(provisional ? { provisional } : {}) }),
  })

/** Deliver the whole world as the core would, to whatever is subscribed. */
const deliver = (h: Harness, w: ReturnType<typeof world>, edit: (row: Row) => Row = (row) => row) => {
  const rows: Row[] = [w.me, ...w.peers, ...w.chats, ...w.dialogs, ...w.messages, w.last11, w.draft].map(edit)
  const lists = []
  const resources = []
  for (const query of h.openSubs()) {
    const sub = h.sub((candidate) => candidate === query)
    if (query.kind === "me") lists.push({ sub, op: "replace" as const, keys: keys(w.me) })
    if (query.kind === "sidebar") lists.push({ sub, op: "replace" as const, keys: keys(...w.dialogs) })
    if (query.kind === "chatWindow") {
      lists.push({ sub, op: "replace" as const, keys: keys(...w.messages) })
      resources.push({ sub, value: windowResource() })
    }
    if (query.kind === "core") resources.push({ sub, value: coreResource() })
  }
  h.endpoint.patch({ rows: upserts(...rows), lists, resources })
}

const exported = async () => {
  const h = harness()
  const w = world()
  const first = session(h)
  const lease = first.openChat(cid(10))
  deliver(h, w)
  await h.flush()
  const data = first.exportProvisional({ chatId: cid(10) })!
  const view = {
    items: first.sidebar.items.peek(),
    item: first.sidebar.items.peek().map((key) => first.sidebar.item(key).peek()),
    rowKeys: lease.model.rowKeys.peek(),
    header: lease.model.header.peek(),
    draft: lease.model.draft.peek(),
    me: first.me.peek(),
  }
  lease.release()
  first.dispose()
  return { w, data: JSON.parse(JSON.stringify(data)) as ClientSnapshotData, view }
}

describe("AccountSession from a boot snapshot", () => {
  it("exports the user, the visible sidebar and the chat window with the rows each needs", async () => {
    const { data, w } = await exported()
    expect(data.queries.map((entry) => entry.query.kind)).toEqual(["me", "sidebar", "chatWindow"])
    const rowKeys = new Set(data.store.rows.map(rowKeyOf))
    for (const row of [w.me, ...w.peers, ...w.chats, ...w.dialogs, ...w.messages, w.last11, w.draft]) {
      expect(rowKeys.has(rowKeyOf(row))).toBe(true)
    }
    expect(data.queries.some((entry) => entry.query.kind === "core")).toBe(false)
  })

  it("restores to the same view state in the same task, before the core answers", async () => {
    const { data, view } = await exported()
    const h = harness()
    const next = session(h, data)
    const lease = next.openChat(cid(10))
    expect(next.restoredFromSnapshot).toBe(true)
    expect(next.sidebar.items.peek()).toEqual(view.items)
    expect(next.sidebar.items.peek().map((key) => next.sidebar.item(key).peek())).toEqual(view.item)
    expect(lease.model.rowKeys.peek()).toEqual(view.rowKeys)
    expect(lease.model.window.peek().ready).toBe(true)
    expect(lease.model.header.peek()).toEqual(view.header)
    // The composer waits for the core's draft (the restored one may be older);
    // the sidebar shows the restored one meanwhile.
    expect(view.draft?.text).toBe("half a thought")
    expect(lease.model.draft.peek()).toBeUndefined()
    expect(next.sidebar.item(view.items[0]!).peek()?.preview).toEqual({ kind: "draft", text: "half a thought" })
    expect(next.me.peek()).toEqual(view.me)
    // One subscription per query: the models took the restored ones over.
    const kinds = h.openSubs().map((query) => query.kind)
    expect(kinds.filter((kind) => kind === "chatWindow")).toHaveLength(1)
    expect(kinds.filter((kind) => kind === "me")).toHaveLength(1)
    expect(h.openSubs().filter((query) => query.kind === "sidebar" && query.mode === "inbox")).toHaveLength(1)
    lease.release()
    next.dispose()
    expect(h.openSubs()).toEqual([])
  })

  it("is ready from the snapshot, and finds the restored chats' dialogs, before the core answers", async () => {
    const { data, w } = await exported()
    const h = harness()
    const next = session(h, data)
    expect(next.sidebar.ready.peek()).toBe(true)
    expect(next.dialogFor(cid(10)).peek()).toMatchObject({ unreadCount: 1 })
    const lease = next.openChat(cid(10))
    expect(lease.model.readState.peek()).toEqual({ unreadCount: 1 })
    expect(w.dialogs[0]!.chatId).toBe(cid(10))
    lease.release()
    next.dispose()
  })

  it("keeps row and item identity when the core confirms equal rows, and replaces changed ones", async () => {
    const { data, w } = await exported()
    const h = harness()
    const next = session(h, data)
    const lease = next.openChat(cid(10))
    const [first, second] = next.sidebar.items.peek()
    const itemA = next.sidebar.item(first!)
    const itemB = next.sidebar.item(second!)
    const renders = { a: 0, b: 0, rows: 0 }
    const stops = [
      effect(() => void (itemA.get(), renders.a++)),
      effect(() => void (itemB.get(), renders.b++)),
      effect(() => void (lease.model.rowKeys.get(), renders.rows++)),
    ]
    const before = { a: itemA.peek(), message: lease.model.row(rowKeyOf(w.messages[0]!)).peek() }
    // The context's first snapshot comes before anything is computed.
    h.endpoint.deliver({ kind: "snapshot", snapshot: { revision: 1, rows: [], lists: [], resources: [], settled: [] } })
    await h.flush()
    expect(next.sidebar.items.peek()).toHaveLength(2)
    // Then the real rows: the same except a new unread in Grace's chat.
    deliver(h, w, (row) => (row.kind === "dialog" && row.chatId === cid(11) ? { ...row, unreadCount: 4 } : { ...row }))
    await h.flush()
    expect(itemA.peek()).toBe(before.a)
    expect(itemB.peek()?.unreadCount).toBe(4)
    expect(lease.model.row(rowKeyOf(w.messages[0]!)).peek()).toBe(before.message)
    expect(renders).toEqual({ a: 1, b: 2, rows: 1 })
    expect(lease.model.draft.peek()?.text).toBe("half a thought")
    expect(next.client.store.provisionalSubs.peek().size).toBe(0)
    for (const stop of stops) stop()
    lease.release()
    next.dispose()
  })

  it("releases a restored chat window no pane took once the core is ready", async () => {
    const { data } = await exported()
    const h = harness()
    const next = session(h, data)
    expect(h.openSubs().some((query) => query.kind === "chatWindow")).toBe(true)
    h.endpoint.patch({ resources: [{ sub: h.sub((query) => query.kind === "core"), value: coreResource() }] })
    await h.flush()
    expect(h.openSubs().some((query) => query.kind === "chatWindow")).toBe(false)
    next.dispose()
  })

  it("does not hand a restored window to a chat opened at a message", async () => {
    const { data } = await exported()
    const h = harness()
    const next = session(h, data)
    const lease = next.openChat(cid(10), { around: mid(2) })
    const windows = h.openSubs().filter((query) => query.kind === "chatWindow")
    expect(windows).toHaveLength(2)
    expect(lease.model.window.peek().ready).toBe(false)
    lease.release()
    next.dispose()
  })

  it("names the rows a row needs", () => {
    const w = world()
    expect(relatedRowKeys(w.dialogs[0]!)).toEqual(["chat:10", "user:2", "draft:10"])
    expect(relatedRowKeys(w.chats[0]!)).toEqual(["user:2", `message:${receivedMessageRowId(cid(10), mid(3))}`])
    expect(relatedRowKeys(w.messages[1]!)).toEqual(["user:2", "chat:10", "draft:10"])
    expect(relatedRowKeys(w.me)).toEqual([])
  })
})

export type { SidebarItem }
