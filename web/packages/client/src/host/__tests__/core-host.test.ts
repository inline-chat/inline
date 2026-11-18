import {
  optimisticMessageRow,
  rowKey,
  sentMessageRowId,
  type DialogRow,
  type Intent,
  type MessageRow,
} from "@inline/core-protocol"
import { chatId, dialogId, messageId, userId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { DbObjectKind, messageKey, type DbModel } from "../../database/models"
import { CoreHost } from "../core-host"
import {
  FakeDisk,
  me,
  newMessageUpdate,
  ScriptedTransport,
  TestContext,
  updateMessageIdUpdate,
} from "./fixtures"

const peer = userId(8)
const thread = chatId(600)
const dm = chatId(20)
const archivedChat = chatId(700)

const seed = (): DbModel[] => [
  { kind: DbObjectKind.User, id: me, firstName: "Mo" },
  { kind: DbObjectKind.User, id: peer, firstName: "Dena" },
  { kind: DbObjectKind.Chat, id: thread, title: "Design", lastMsgId: messageId(3), date: 102 },
  { kind: DbObjectKind.Chat, id: dm, peerUserId: peer, date: 50 },
  { kind: DbObjectKind.Chat, id: archivedChat, title: "Old", date: 200 },
  {
    kind: DbObjectKind.Dialog,
    id: dialogId(-600),
    chatId: thread,
    peerThreadId: thread,
    open: true,
    order: "b",
    readMaxId: messageId(3),
  },
  { kind: DbObjectKind.Dialog, id: dialogId(8), chatId: dm, peerUserId: peer, open: true, order: "a" },
  {
    kind: DbObjectKind.Dialog,
    id: dialogId(-700),
    chatId: archivedChat,
    peerThreadId: archivedChat,
    archived: true,
  },
  ...[1, 2, 3].map(
    (id): DbModel => ({
      kind: DbObjectKind.Message,
      id: messageKey(thread, messageId(id)),
      messageId: messageId(id),
      chatId: thread,
      fromId: peer,
      message: `Message ${id}`,
      date: 99 + id,
    }),
  ),
]

const hosts: CoreHost[] = []

const startHost = (disk: FakeDisk, transport = new ScriptedTransport(), pageSize?: number) => {
  const host = new CoreHost({
    ...(pageSize ? { pageSize } : {}),
    buildId: "2026-11-17T00:00:00Z-test",
    openStorage: () => disk.storage(),
    createTransport: () => transport,
    realtime: { sync: false },
    now: () => 1_000_000,
  })
  hosts.push(host)
  return { host, transport }
}

const signIn = (context: TestContext) =>
  context.post({ kind: "session", action: "start", session: { userId: me, token: "token" } })

afterEach(async () => {
  await Promise.all(hosts.splice(0).map((host) => host.shutdown()))
})

/** Every patch names the revision before it; the first follows the opening snapshot. */
const expectContiguous = (context: TestContext) => {
  let revision = 1
  for (const patch of context.patches) {
    expect(patch.base).toBe(revision)
    expect(patch.revision).toBe(revision + 1)
    revision = patch.revision
  }
}

describe("CoreHost", () => {
  it("opens with a snapshot, then serves the sidebar and a chat window from local data", async () => {
    const disk = new FakeDisk()
    await disk.seed(seed())
    const { host } = startHost(disk)
    const ui = new TestContext(host)
    await ui.until(() => ui.snapshots === 1, "opening snapshot")
    expect(ui.state.revision).toBe(1)

    signIn(ui)
    ui.subscribeTo(1, { kind: "core" })
    ui.subscribeTo(2, { kind: "sidebar", mode: "inbox" })
    ui.subscribeTo(3, { kind: "chatWindow", chatId: thread, anchor: "latest" })
    await ui.until(
      () => ui.list(2).length === 2 && ui.list(3).length === 3,
      "sidebar and window",
    )

    expect(ui.core(1)).toMatchObject({ phase: "ready", userId: me, storage: "persistent" })
    // Inbox: open dialogs ordered by `order`; the archived one is left out.
    expect(ui.rows(2).map((row) => (row as DialogRow).chatId)).toEqual([dm, thread])
    // The chat and peer rows the sidebar needs come with it.
    expect(ui.state.rows.get(rowKey("chat", thread))).toMatchObject({ title: "Design" })
    expect(ui.state.rows.get(rowKey("user", peer))).toMatchObject({ firstName: "Dena" })
    expect(ui.rows(3).map((row) => (row as MessageRow).text)).toEqual([
      "Message 1",
      "Message 2",
      "Message 3",
    ])
    expect(ui.window(3)).toMatchObject({ atLatest: true, hasNewer: false, unreadBoundary: "3" })
    expectContiguous(ui)
  })

  it("sends text: the optimistic row, then the confirmed row under the same ID", async () => {
    const disk = new FakeDisk()
    await disk.seed(seed())
    const { host, transport } = startHost(disk)
    const ui = new TestContext(host)
    signIn(ui)
    ui.subscribeTo(1, { kind: "sidebar", mode: "inbox" })
    ui.subscribeTo(2, { kind: "chatWindow", chatId: thread, anchor: "latest" })
    await ui.until(() => ui.list(2).length === 3, "window")

    const intent: Extract<Intent, { kind: "sendText" }> = {
      kind: "sendText",
      chatId: thread,
      clientKey: "4242424242",
      text: "Hello",
      date: 500,
    }
    const rowId = sentMessageRowId(thread, intent.clientKey)
    const key = rowKey("message", rowId)
    ui.post({ kind: "intent", tx: "tx-1", intent })

    await ui.until(() => ui.result("tx-1", "accepted") != null, "accepted")
    await ui.until(() => ui.list(2).includes(key), "optimistic row")
    // The core commits exactly the row the UI predicted for its overlay
    // (with the intent's transaction ID, `MessageRow.tx`).
    expect(ui.state.rows.get(key)).toEqual(optimisticMessageRow(intent, me, 500, "tx-1"))
    expect(ui.list(2).at(-1)).toBe(key)
    expect(ui.result("tx-1", "accepted")?.rows).toEqual([key])
    // Accepted means durable: the outbox row, the record of its transaction
    // ID and the message are on disk.
    expect(await disk.count("pending_transaction")).toBe(2)

    await transport.open()
    const request = await transport.rpc("sendMessage")
    if (request.body.oneofKind !== "rpcCall" || request.body.rpcCall.input.oneofKind !== "sendMessage") {
      throw new Error("expected sendMessage")
    }
    expect(request.body.rpcCall.input.sendMessage.randomId).toBe(4242424242n)
    await transport.reply(request, {
      oneofKind: "sendMessage",
      sendMessage: {
        addedUserIds: [],
        unaddedUserIds: [],
        updates: [
          updateMessageIdUpdate(900n, 4242424242n),
          newMessageUpdate({
            id: 900n,
            chatId: 600n,
            fromId: 7n,
            out: true,
            message: "Hello",
            date: 500n,
          } as never),
        ],
      },
    })

    await ui.until(() => ui.result("tx-1", "confirmed") != null, "confirmed")
    await ui.until(() => (ui.state.rows.get(key) as MessageRow | undefined)?.state === "sent", "sent row")
    expect(ui.state.rows.get(key)).toMatchObject({
      id: rowId,
      messageId: "900",
      clientKey: intent.clientKey,
      state: "sent",
      text: "Hello",
    })
    // Off the outbox: the row no longer names a transaction, and its record is gone.
    expect((ui.state.rows.get(key) as MessageRow).tx).toBeUndefined()
    // The record is swept once the intent's task sees the send land.
    let records = await disk.count("pending_transaction")
    for (let turn = 0; records > 0 && turn < 50; turn++) {
      await host.idle()
      records = await disk.count("pending_transaction")
    }
    expect(records).toBe(0)
    expect(ui.list(2)).toEqual([
      rowKey("message", `${thread}:1`),
      rowKey("message", `${thread}:2`),
      rowKey("message", `${thread}:3`),
      key,
    ])
    // The row never changed identity: no patch removed it, and no other key
    // for message 900 ever appeared.
    for (const patch of ui.patches) {
      for (const change of patch.rows) {
        if (change.op === "remove") expect(change.id).not.toBe(rowId)
        else if (change.row.kind === "message") expect(change.row.id).not.toBe(`${thread}:900`)
      }
    }
    // The sidebar follows: the thread's chat row now names the new last message.
    expect(ui.state.rows.get(rowKey("chat", thread))).toMatchObject({ lastMessageId: "900" })
    expect(await disk.count("pending_transaction")).toBe(0)
    expectContiguous(ui)
  })

  it("answers a revision gap with a snapshot equal to a fresh context's state", async () => {
    const disk = new FakeDisk()
    await disk.seed(seed())
    const { host } = startHost(disk)
    const ui = new TestContext(host)
    signIn(ui)
    ui.subscribeTo(1, { kind: "sidebar", mode: "inbox" })
    ui.subscribeTo(2, { kind: "chatWindow", chatId: thread, anchor: "latest" })
    ui.subscribeTo(3, { kind: "draft", chatId: thread })
    await ui.until(() => ui.list(1).length === 2 && ui.list(2).length === 3, "loaded")

    ui.drop = 1
    ui.post({ kind: "intent", tx: "d1", intent: { kind: "saveDraft", chatId: thread, text: "one", revision: 1 } })
    await host.idle()
    expect(ui.drop).toBe(0)
    ui.post({ kind: "intent", tx: "d2", intent: { kind: "saveDraft", chatId: thread, text: "two", revision: 2 } })
    await ui.until(() => ui.snapshots === 2, "resync snapshot")
    await host.idle()
    expect(ui.gaps).toBe(1)

    const fresh = new TestContext(host.openContext())
    fresh.subscribeTo(1, { kind: "sidebar", mode: "inbox" })
    fresh.subscribeTo(2, { kind: "chatWindow", chatId: thread, anchor: "latest" })
    fresh.subscribeTo(3, { kind: "draft", chatId: thread })
    await fresh.until(() => fresh.list(3).length === 1 && fresh.list(2).length === 3, "fresh")
    await host.idle()

    expect(ui.state.rows).toEqual(fresh.state.rows)
    expect(ui.state.lists).toEqual(fresh.state.lists)
    expect(ui.state.rows.get(rowKey("draft", thread))).toMatchObject({ text: "two", revision: 2 })
    // Results that settled in the lost patch reach the context with the snapshot.
    expect(ui.result("d1", "confirmed")).toBeDefined()
    expect(ui.result("d2", "confirmed")).toBeDefined()
    fresh.close()
  })

  it("removes rows a context no longer needs", async () => {
    const disk = new FakeDisk()
    await disk.seed(seed())
    const { host } = startHost(disk)
    const ui = new TestContext(host)
    signIn(ui)
    ui.subscribeTo(1, { kind: "chatWindow", chatId: thread, anchor: "latest" })
    ui.subscribeTo(2, { kind: "user", userId: peer })
    await ui.until(() => ui.list(1).length === 3 && ui.list(2).length === 1, "loaded")

    ui.post({ kind: "unsubscribe", sub: 1 })
    await ui.until(() => !ui.state.rows.has(rowKey("message", `${thread}:1`)), "messages removed")
    // The peer row is still held by the user subscription.
    expect(ui.state.rows.has(rowKey("user", peer))).toBe(true)
    ui.post({ kind: "unsubscribe", sub: 2 })
    await ui.until(() => ui.state.rows.size === 0, "all rows removed")
    expectContiguous(ui)
  })

  it("rejects an unsupported intent, and any intent before sign-in, as data", async () => {
    const disk = new FakeDisk()
    await disk.seed(seed())
    const { host } = startHost(disk)
    const ui = new TestContext(host)

    ui.post({ kind: "intent", tx: "early", intent: { kind: "markRead", chatId: thread, maxId: messageId(3) } })
    await ui.until(() => ui.result("early") != null, "early result")
    expect(ui.result("early")).toEqual({ tx: "early", status: "rejected", reason: "notSignedIn" })

    signIn(ui)
    ui.post({
      kind: "intent",
      tx: "future",
      intent: { kind: "pinMessage", chatId: thread, messageId: messageId(1) } as unknown as Intent,
    })
    await ui.until(() => ui.result("future") != null, "unknown kind result")
    expect(ui.result("future")).toEqual({ tx: "future", status: "rejected", reason: "unsupported" })

    // An edit is not replay-safe: offline it is refused before anything shows.
    ui.post({
      kind: "intent",
      tx: "edit",
      intent: { kind: "editText", chatId: thread, messageId: messageId(1), text: "x" },
    })
    await ui.until(() => ui.result("edit") != null, "edit result")
    expect(ui.result("edit")).toEqual({ tx: "edit", status: "rejected", reason: "offline" })

    ui.post({
      kind: "intent",
      tx: "bad",
      intent: { kind: "sendText", chatId: thread, clientKey: "01", text: "x" },
    })
    await ui.until(() => ui.result("bad") != null, "bad result")
    expect(ui.result("bad")).toMatchObject({ status: "rejected", reason: "invalid" })
  })

  it("answers a repeated intent and a repeated session start without applying them twice", async () => {
    const disk = new FakeDisk()
    await disk.seed(seed())
    const { host } = startHost(disk)
    const ui = new TestContext(host)
    signIn(ui)
    ui.subscribeTo(1, { kind: "core" })
    ui.subscribeTo(2, { kind: "chatWindow", chatId: thread, anchor: "latest" })
    await ui.until(() => ui.list(2).length === 3, "window")

    const intent: Intent = { kind: "sendText", chatId: thread, clientKey: "77", text: "Once", date: 10 }
    ui.post({ kind: "intent", tx: "once", intent })
    await ui.until(() => ui.result("once", "accepted") != null, "accepted")
    signIn(ui)
    ui.post({ kind: "intent", tx: "once", intent })
    // The same send under a new transaction ID (a replay after a handoff).
    ui.post({ kind: "intent", tx: "once-again", intent })
    await ui.until(() => ui.result("once-again", "accepted") != null, "replayed")
    await host.idle()

    expect(ui.settled.filter((result) => result.tx === "once")).toHaveLength(2)
    // One outbox row and the record of its transaction ID.
    expect(await disk.count("pending_transaction")).toBe(2)
    expect(ui.list(2).filter((key) => key.includes(":r77"))).toHaveLength(1)
    expect(disk.opened).toBe(1)
    expect(ui.core(1)?.phase).toBe("ready")
  })

  it("saves drafts durably and keeps them across a restart", async () => {
    const disk = new FakeDisk()
    await disk.seed(seed())
    const first = startHost(disk)
    const ui = new TestContext(first.host)
    signIn(ui)
    ui.subscribeTo(1, { kind: "draft", chatId: dm })
    ui.post({
      kind: "intent",
      tx: "draft",
      intent: {
        kind: "saveDraft",
        chatId: dm,
        text: "Half a thought",
        revision: 3,
        entities: [{ type: "bold", offset: 0, length: 4 }],
      },
    })
    await ui.until(() => ui.result("draft", "confirmed") != null, "draft saved")
    await ui.until(() => ui.list(1).length === 1, "draft row")
    expect(ui.rows(1)[0]).toEqual({
      kind: "draft",
      id: dm,
      text: "Half a thought",
      entities: [{ type: "bold", offset: 0, length: 4 }],
      revision: 3,
    })
    // A stale save loses to the stored revision.
    ui.post({ kind: "intent", tx: "stale", intent: { kind: "saveDraft", chatId: dm, text: "old", revision: 2 } })
    await ui.until(() => ui.result("stale", "confirmed") != null, "stale")
    await first.host.shutdown()
    expect(disk.erased).toBe(0)

    const second = startHost(disk)
    const again = new TestContext(second.host)
    signIn(again)
    again.subscribeTo(1, { kind: "draft", chatId: dm })
    await again.until(() => again.list(1).length === 1, "draft after restart")
    expect(again.rows(1)[0]).toMatchObject({ text: "Half a thought", revision: 3 })
  })

  it("signs out: stops the core, erases the replica, empties every subscription", async () => {
    const disk = new FakeDisk()
    await disk.seed(seed())
    const { host } = startHost(disk)
    const ui = new TestContext(host)
    signIn(ui)
    ui.subscribeTo(1, { kind: "core" })
    ui.subscribeTo(2, { kind: "sidebar", mode: "all" })
    await ui.until(() => ui.list(2).length === 2, "sidebar")

    ui.post({ kind: "session", action: "signOut" })
    await ui.until(() => ui.core(1)?.phase === "signedOut", "signed out")
    expect(ui.list(2)).toEqual([])
    expect(ui.state.rows.size).toBe(0)
    expect(ui.core(1)).not.toHaveProperty("userId")
    expect(disk.erased).toBe(1)
    expect(await disk.count("dialog")).toBe(0)

    // Signing in again starts from an empty replica.
    signIn(ui)
    await ui.until(() => ui.core(1)?.phase === "ready", "ready again")
    await host.idle()
    expect(ui.list(2)).toEqual([])
    expectContiguous(ui)
  })

  it("stops on an outdated phase for a replica from a newer schema", async () => {
    const disk = new FakeDisk()
    await disk.seed(seed())
    await disk.exec(
      "INSERT INTO inline_schema_migration(version, name, applied_at) VALUES (99, 'future', 0)",
    )
    const { host } = startHost(disk)
    const ui = new TestContext(host)
    signIn(ui)
    ui.subscribeTo(1, { kind: "core" })
    ui.subscribeTo(2, { kind: "sidebar", mode: "all" })
    await ui.until(() => ui.core(1)?.phase === "outdated", "outdated")
    await host.idle()
    expect(ui.list(2)).toEqual([])
    // The newer replica is left alone.
    expect(await disk.count("dialog")).toBe(3)

    ui.post({ kind: "intent", tx: "t", intent: { kind: "markRead", chatId: thread, maxId: messageId(3) } })
    await ui.until(() => ui.result("t") != null, "rejected")
    expect(ui.result("t")).toMatchObject({ status: "rejected", reason: "unavailable" })
  })

  it("forwards browser signals to the connection", async () => {
    const disk = new FakeDisk()
    await disk.seed(seed())
    const { host } = startHost(disk)
    const ui = new TestContext(host)
    signIn(ui)
    ui.subscribeTo(1, { kind: "core" })
    await ui.until(() => ui.core(1)?.phase === "ready", "ready")
    ui.post({ kind: "signal", signal: { kind: "online", online: false } })
    await ui.until(() => ui.core(1)?.connection === "waitingForNetwork", "offline")
    ui.post({ kind: "signal", signal: { kind: "online", online: true } })
    await ui.until(() => ui.core(1)?.connection !== "waitingForNetwork", "online")
    ui.post({ kind: "signal", signal: { kind: "visibility", visible: false } })
    ui.post({ kind: "signal", signal: { kind: "wake" } })
    await host.idle()
    expect(ui.core(1)?.phase).toBe("ready")
  })

  it("marks read and reports the dialog change", async () => {
    const disk = new FakeDisk()
    const unread = seed().map((object) =>
      object.kind === DbObjectKind.Dialog && object.chatId === thread
        ? { ...object, readMaxId: messageId(1), unreadCount: 2 }
        : object,
    )
    await disk.seed(unread)
    const { host, transport } = startHost(disk)
    const ui = new TestContext(host)
    signIn(ui)
    ui.subscribeTo(1, { kind: "sidebar", mode: "inbox" })
    await ui.until(() => ui.list(1).length === 2, "sidebar")
    const dialogKey = rowKey("dialog", dialogId(-600))
    expect(ui.state.rows.get(dialogKey)).toMatchObject({ unreadCount: 2 })

    ui.post({ kind: "intent", tx: "read", intent: { kind: "markRead", chatId: thread, maxId: messageId(3) } })
    await ui.until(() => ui.result("read", "accepted") != null, "accepted")
    await ui.until(
      () => (ui.state.rows.get(dialogKey) as DialogRow | undefined)?.unreadCount === 0,
      "read",
    )
    expect(ui.state.rows.get(dialogKey)).toMatchObject({ readMaxId: "3" })

    await transport.open()
    const request = await transport.rpc("readMessages")
    await transport.reply(request, { oneofKind: "readMessages", readMessages: { updates: [] } } as never)
    await ui.until(() => ui.result("read", "confirmed") != null, "confirmed")
  })
  it("refuses an intent whose commit fails for space, and never shows its row", async () => {
    const disk = new FakeDisk()
    await disk.seed(seed())
    const { host } = startHost(disk)
    const ui = new TestContext(host)
    signIn(ui)
    ui.subscribeTo(1, { kind: "core" })
    ui.subscribeTo(2, { kind: "chatWindow", chatId: thread, anchor: "latest" })
    await ui.until(() => ui.list(2).length === 3, "window")

    disk.failNextWrite = Object.assign(new Error("disk full"), { name: "QuotaExceededError" })
    ui.post({
      kind: "intent",
      tx: "full",
      intent: { kind: "sendText", chatId: thread, clientKey: "5", text: "Lost?", date: 1 },
    })
    await ui.until(() => ui.result("full") != null, "result")
    expect(ui.result("full")).toEqual({ tx: "full", status: "rejected", reason: "storageFull" })
    await ui.until(() => ui.core(1)?.storage === "full", "storage full")
    await host.idle()
    const sentKey = rowKey("message", sentMessageRowId(thread, "5"))
    for (const patch of ui.patches) {
      for (const change of patch.rows) {
        if (change.op === "upsert") expect(rowKey(change.row.kind, change.row.id)).not.toBe(sentKey)
      }
    }
    expect(await disk.count("pending_transaction")).toBe(0)

    // The next intent probes storage; when it commits, the state clears.
    ui.post({
      kind: "intent",
      tx: "retry",
      intent: { kind: "sendText", chatId: thread, clientKey: "5", text: "Lost?", date: 1 },
    })
    await ui.until(() => ui.result("retry", "accepted") != null, "accepted on retry")
    await ui.until(() => ui.core(1)?.storage === "persistent", "storage back")
    expect(ui.list(2)).toContain(sentKey)
  })

  it("pages older history: local while offline, then from the server until it runs out", async () => {
    const disk = new FakeDisk()
    const history: DbModel[] = Array.from({ length: 60 }, (_, index): DbModel => ({
      kind: DbObjectKind.Message,
      id: messageKey(thread, messageId(index + 1)),
      messageId: messageId(index + 1),
      chatId: thread,
      fromId: peer,
      message: `m${index + 1}`,
      date: 1_000 + index,
    }))
    await disk.seed([
      ...seed().filter((object) => object.kind !== DbObjectKind.Message),
      ...history.slice(20),
    ])
    const { host, transport } = startHost(disk, new ScriptedTransport(), 20)
    const ui = new TestContext(host)
    signIn(ui)
    ui.subscribeTo(1, { kind: "chatWindow", chatId: thread, anchor: "latest" })
    ui.subscribeTo(2, { kind: "core" })
    await ui.until(() => ui.list(1).length === 20, "latest local page")
    expect(ui.window(1)).toMatchObject({ hasOlder: true, atLatest: true, loading: "none" })

    ui.post({ kind: "ensure", sub: 1, range: "older" })
    await ui.until(() => ui.list(1).length === 40, "older local page")
    await host.idle()
    expect((ui.rows(1)[0] as MessageRow).text).toBe("m21")

    await transport.open()
    await ui.until(() => ui.core(2)?.connection === "connected", "connected")
    ui.post({ kind: "ensure", sub: 1, range: "older" })
    // The window's background refresh asked for the latest page; this one pages back.
    const older = await transport.rpc(
      "getChatHistory",
      (message) =>
        message.body.oneofKind === "rpcCall" &&
        message.body.rpcCall.input.oneofKind === "getChatHistory" &&
        message.body.rpcCall.input.getChatHistory.beforeId != null,
    )
    if (older.body.oneofKind !== "rpcCall" || older.body.rpcCall.input.oneofKind !== "getChatHistory") {
      throw new Error("expected getChatHistory")
    }
    expect(older.body.rpcCall.input.getChatHistory.beforeId).toBe(21n)
    await transport.reply(older, {
      oneofKind: "getChatHistory",
      getChatHistory: {
        messages: history.slice(0, 20).map((object) => {
          const message = object as Extract<DbModel, { kind: DbObjectKind.Message }>
          return {
            id: BigInt(message.messageId),
            chatId: 600n,
            fromId: 8n,
            out: false,
            message: message.message,
            date: BigInt(message.date!),
          }
        }),
      },
    } as never)
    await ui.until(() => ui.list(1).length === 60, "server page")
    expect((ui.rows(1)[0] as MessageRow).text).toBe("m1")
    // The page certified [1, 20], so the window knows it reached the start
    // (invariant 5) and paging older asks the server for nothing.
    const sentBefore = transport.sent.length
    ui.post({ kind: "ensure", sub: 1, range: "older" })
    await host.idle()
    expect(transport.sent.length).toBe(sentBefore)
    await ui.until(() => ui.window(1)?.hasOlder === false, "no older history")
    expectContiguous(ui)
  })
})

