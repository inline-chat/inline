import { describe, expect, it } from "vitest"
import type { Intent, MessageRow } from "@inline/core-protocol"
import { rowKey, sentMessageRowId } from "@inline/core-protocol"
import { message } from "@inline/reactive/testing"
import { ChatModel, composerOutcome } from "./chat-model"
import { chatRow, cid, dialogRow, draftRow, harness, keys, mid, uid, upserts, userRow, windowResource } from "./test-support"

const me = uid(1)

const setup = (options: { anchor?: "latest" } = {}) => {
  const h = harness()
  let nextKey = 100
  const model = new ChatModel({
    client: h.client,
    chatId: cid(5),
    userId: me,
    clock: h.time,
    now: () => 1_800_000_000_000,
    random: () => 0.5,
    newClientKey: () => String(nextKey++),
    ...(options.anchor ? { anchor: options.anchor } : {}),
  })
  const release = model.retain()
  const windowSub = h.sub((query) => query.kind === "chatWindow")
  const history = [message(5, 1, "one"), message(5, 2, "two")]
  const openWindow = async (resource = windowResource()) => {
    h.endpoint.patch({
      rows: upserts(...history, chatRow(5, { title: "Ops" })),
      lists: [{ sub: windowSub, op: "replace", keys: keys(...history) }],
      resources: [{ sub: windowSub, value: resource }],
    })
    await h.flush()
  }
  return { ...h, model, release, windowSub, history, openWindow }
}

const lastIntent = (s: ReturnType<typeof setup>) => {
  const command = s.endpoint.commands("intent").at(-1)!
  return { tx: command.tx, intent: command.intent }
}

describe("ChatModel", () => {
  it("subscribes to the window at the unread line, the chat and the draft", () => {
    const s = setup()
    expect(s.openSubs()).toEqual([
      { kind: "chatWindow", chatId: cid(5), anchor: "unread" },
      { kind: "chat", chatId: cid(5) },
      { kind: "draft", chatId: cid(5) },
    ])
    expect(s.model.window.peek()).toMatchObject({ ready: false, loading: "initial" })
  })

  it("exposes rows by key, the window state and the header", async () => {
    const s = setup()
    await s.openWindow(windowResource({ hasOlder: true, unreadBoundary: mid(1) }))
    expect(s.model.rowKeys.peek()).toEqual(keys(...s.history))
    expect(s.model.row(keys(s.history[1]!)[0]!).peek()?.text).toBe("two")
    expect(s.model.window.peek()).toEqual({
      ready: true,
      hasOlder: true,
      hasNewer: false,
      atLatest: true,
      loading: "none",
      unreadBoundary: mid(1),
    })
    expect(s.model.header.peek()).toMatchObject({ title: "Ops", isDirect: false, peerIsBot: false })
    s.model.ensureOlder()
    s.model.request({ around: mid(1) })
    expect(s.endpoint.commands("ensure").map((c) => c.range)).toEqual(["older", { around: mid(1) }])
  })

  it("subscribes to a direct message's peer and titles the chat with the peer's name", async () => {
    const s = setup()
    s.endpoint.patch({ rows: upserts(chatRow(5, { peerUserId: uid(9) })) })
    await s.flush()
    // The effect follows the chat row, so the subscription starts once it is read.
    expect(s.openSubs()).toContainEqual({ kind: "user", userId: uid(9) })
    s.endpoint.patch({ rows: upserts(userRow(9, "Grace", { lastName: "Hopper", bot: true })) })
    await s.flush()
    expect(s.model.header.peek()).toMatchObject({ title: "Grace Hopper", isDirect: true, peerIsBot: true })
  })

  it("shows a send in the list in the same task and keeps its key when the core confirms it", async () => {
    const s = setup()
    await s.openWindow()
    const handle = s.model.send("hello", [], undefined)
    const key = rowKey("message", sentMessageRowId(cid(5), "100"))
    expect(handle.rowKey).toBe(key)
    // Readable before any frame or microtask.
    expect(s.model.rowKeys.peek()).toEqual([...keys(...s.history), key])
    const echo = s.model.row(key).peek()!
    expect(echo).toMatchObject({ text: "hello", state: "sending", out: true, fromId: me, date: 1_800_000_000 })

    const { tx, intent } = lastIntent(s)
    expect(intent).toEqual({ kind: "sendText", chatId: cid(5), clientKey: "100", text: "hello", date: 1_800_000_000 })
    expect(handle.tx).toBe(tx)

    // The core commits the same row, then the server assigns its ID.
    const committed: MessageRow = { ...echo }
    s.endpoint.patch({
      rows: upserts(committed),
      lists: [{ sub: s.windowSub, op: "splice", index: 2, remove: 0, insert: [key] }],
      settled: [{ tx, status: "accepted", rows: [key] }],
    })
    await s.flush()
    expect(await handle).toEqual({ status: "accepted", tx, rowKey: key, clientKey: "100" })
    expect(s.model.rowKeys.peek()).toEqual([...keys(...s.history), key])

    s.endpoint.patch({ rows: upserts({ ...committed, messageId: mid(3), state: "sent" }), settled: [{ tx, status: "confirmed" }] })
    await s.flush()
    expect(s.model.rowKeys.peek()).toEqual([...keys(...s.history), key])
    expect(s.model.row(key).peek()).toMatchObject({ messageId: mid(3), state: "sent" })
  })

  it("a send consumes the draft revision it was made from, and its row carries the transaction ID", async () => {
    const s = setup()
    await s.openWindow()
    const outcome = s.model.sendFromComposer({ kind: "send", text: "from the draft", entities: [], revision: 7 })
    const { tx, intent } = lastIntent(s)
    expect(intent).toMatchObject({ kind: "sendText", text: "from the draft", draftRevision: 7 })
    const key = rowKey("message", sentMessageRowId(cid(5), "100"))
    // The prediction is the core's row as it will be while the send is in the outbox (`MessageRow.tx`).
    const echo = s.model.row(key).peek()!
    expect(echo.tx).toBe(tx)
    expect(s.model.rowKeys.peek()).toEqual([...keys(...s.history), key])
    s.endpoint.patch({
      rows: upserts({ ...echo }),
      lists: [{ sub: s.windowSub, op: "splice", index: 2, remove: 0, insert: [key] }],
      settled: [{ tx, status: "accepted", rows: [key] }],
    })
    await s.flush()
    expect(await outcome).toEqual({ status: "accepted" })
    expect(s.model.rowKeys.peek()).toEqual([...keys(...s.history), key])

    // A retry after an uncertain result sends the same revision again.
    const plain = s.model.send("no draft", [], undefined)
    expect(lastIntent(s).intent).not.toHaveProperty("draftRevision")
    s.endpoint.patch({ settled: [{ tx: plain.tx, status: "rejected", reason: "storageFull" }] })
    const maybe = s.model.send("maybe", [], undefined, { draftRevision: 9 })
    s.endpoint.patch({ settled: [{ tx: maybe.tx, status: "uncertain" }] })
    await s.flush()
    const result = await maybe
    if (result.status !== "uncertain") throw new Error("expected uncertain")
    result.retry()
    expect(lastIntent(s).intent).toMatchObject({ draftRevision: 9, clientKey: result.clientKey })
  })

  it("a rejected send (storage full) leaves nothing in the list and says why", async () => {
    const s = setup()
    await s.openWindow()
    const handle = s.model.send("too much", undefined, mid(2))
    expect(s.model.rowKeys.peek()).toHaveLength(3)
    expect(lastIntent(s).intent).toMatchObject({ replyToMessageId: mid(2) })
    s.endpoint.patch({ settled: [{ tx: handle.tx, status: "rejected", reason: "storageFull" }] })
    await s.flush()
    const result = await handle
    expect(result).toEqual({ status: "rejected", tx: handle.tx, reason: "storageFull", retryable: true })
    expect(composerOutcome(result)).toEqual({ status: "rejected", reason: "storageFull" })
    expect(s.model.rowKeys.peek()).toEqual(keys(...s.history))
    expect(s.model.row(handle.rowKey).peek()).toBeUndefined()
  })

  it("an uncertain send keeps the text and a retry cannot double the message", async () => {
    const s = setup()
    await s.openWindow()
    const outcome = s.model.sendFromComposer({ kind: "send", text: "maybe", entities: [], revision: 4 })
    const first = lastIntent(s)
    s.endpoint.patch({ settled: [{ tx: first.tx, status: "uncertain" }] })
    await s.flush()
    expect(await outcome).toEqual({ status: "rejected", reason: "uncertain" })

    // The composer sends the same revision again: same client key, new transaction.
    const again = s.model.send("maybe", [], undefined, { draftRevision: 4 })
    const second = lastIntent(s)
    expect(second.tx).not.toBe(first.tx)
    expect((second.intent as Extract<Intent, { kind: "sendText" }>).clientKey).toBe(
      (first.intent as Extract<Intent, { kind: "sendText" }>).clientKey,
    )
    s.endpoint.patch({ settled: [{ tx: second.tx, status: "uncertain" }] })
    await s.flush()
    const result = await again
    expect(result.status).toBe("uncertain")
    if (result.status !== "uncertain") return
    const retried = result.retry()
    expect(retried.clientKey).toBe(result.clientKey)
    s.endpoint.patch({ settled: [{ tx: retried.tx, status: "accepted" }] })
    await s.flush()
    expect((await retried).status).toBe("accepted")

    // A different revision is a new message.
    s.model.send("maybe", [], undefined, { draftRevision: 5 })
    expect((lastIntent(s).intent as Extract<Intent, { kind: "sendText" }>).clientKey).not.toBe(result.clientKey)
  })

  it("moves a window that is not at latest instead of appending after a gap", async () => {
    const s = setup()
    await s.openWindow(windowResource({ atLatest: false, hasNewer: true }))
    const handle = s.model.send("from history", [], undefined)
    expect(s.model.rowKeys.peek()).toEqual(keys(...s.history))
    expect(s.model.row(handle.rowKey).peek()?.text).toBe("from history")
    expect(s.endpoint.commands("ensure").map((c) => c.range)).toEqual(["latest"])
  })

  it("keeps the model alive for a send in flight after its last user leaves", async () => {
    const s = setup()
    await s.openWindow()
    const handle = s.model.send("bye", [], undefined)
    s.release()
    expect(s.model.disposed).toBe(false)
    expect(s.openSubs()).toHaveLength(3)
    s.endpoint.patch({ settled: [{ tx: handle.tx, status: "accepted" }] })
    await s.flush()
    expect((await handle).status).toBe("accepted")
    expect(s.model.disposed).toBe(true)
    expect(s.openSubs()).toEqual([])
  })

  it("saves the draft and exposes the saved draft row", async () => {
    const s = setup()
    s.model.saveDraft("draft text", [], 3)
    expect(lastIntent(s).intent).toEqual({ kind: "saveDraft", chatId: cid(5), text: "draft text", revision: 3 })
    s.endpoint.patch({ rows: upserts(draftRow(5, "draft text", 3)) })
    await s.flush()
    expect(s.model.draft.peek()).toMatchObject({ text: "draft text", revision: 3 })
  })

  it("reads the unread state from the dialog it is given", async () => {
    const h = harness()
    const dialog = { get: () => dialogRow(5, { unreadCount: 4, readMaxId: mid(2) }), peek: () => dialogRow(5) }
    const model = new ChatModel({ client: h.client, chatId: cid(5), userId: me, clock: h.time, dialog })
    expect(model.readState.get()).toEqual({ unreadCount: 4, readMaxId: mid(2) })
    model.dispose()
    expect(h.openSubs()).toEqual([])
  })
})

describe("ChatModel.markRead", () => {
  const reads = (s: ReturnType<typeof setup>) =>
    s.endpoint
      .commands("intent")
      .filter((command) => command.intent.kind === "markRead")
      .map((command) => ({ tx: command.tx, maxId: (command.intent as Extract<Intent, { kind: "markRead" }>).maxId }))

  it("sends one frontier at a time, coalesces higher ones and never goes lower", async () => {
    const s = setup()
    s.model.markRead(mid(10))
    s.model.markRead(mid(5))
    s.model.markRead(mid(12))
    s.model.markRead(mid(15))
    expect(reads(s).map((r) => r.maxId)).toEqual([mid(10)])
    s.endpoint.patch({ settled: [{ tx: reads(s)[0]!.tx, status: "accepted" }] })
    await s.flush()
    // The waiting frontier was replaced by the highest one asked for.
    expect(reads(s).map((r) => r.maxId)).toEqual([mid(10), mid(15)])
    s.endpoint.patch({ settled: [{ tx: reads(s)[1]!.tx, status: "accepted" }] })
    await s.flush()
    expect(s.model.readFrontier).toBe(mid(15))
    s.model.markRead(mid(15))
    s.model.markRead(mid(9))
    expect(reads(s)).toHaveLength(2)
    // Numeric order, not string order.
    s.model.markRead(mid(100))
    expect(reads(s).map((r) => r.maxId)).toEqual([mid(10), mid(15), mid(100)])
  })

  it("retries a failed frontier from 0.5 s, doubling to 8 s, and resets on success", async () => {
    const s = setup()
    s.model.markRead(mid(20))
    const delays: number[] = []
    for (let attempt = 0; attempt < 7; attempt++) {
      const pending = reads(s)
      s.endpoint.patch({ settled: [{ tx: pending.at(-1)!.tx, status: "rejected", reason: "unavailable" }] })
      await s.flush()
      const before = reads(s).length
      let waited = 0
      while (reads(s).length === before) {
        s.time.advance(100)
        waited += 100
        await s.flush()
        if (waited > 20_000) throw new Error("no retry")
      }
      delays.push(waited)
    }
    expect(delays).toEqual([500, 1000, 2000, 4000, 8000, 8000, 8000])
    expect(new Set(reads(s).map((r) => r.maxId))).toEqual(new Set([mid(20)]))

    // A higher frontier asked for while waiting goes out with the retry.
    s.model.markRead(mid(25))
    s.endpoint.patch({ settled: [{ tx: reads(s).at(-1)!.tx, status: "rejected", reason: "storageFull" }] })
    await s.flush()
    s.time.advance(8000)
    await s.flush()
    expect(reads(s).at(-1)!.maxId).toBe(mid(25))
    s.endpoint.patch({ settled: [{ tx: reads(s).at(-1)!.tx, status: "accepted" }] })
    await s.flush()

    // After a success the backoff starts again at 0.5 s.
    s.model.markRead(mid(30))
    s.endpoint.patch({ settled: [{ tx: reads(s).at(-1)!.tx, status: "uncertain" }] })
    await s.flush()
    const count = reads(s).length
    s.time.advance(499)
    await s.flush()
    expect(reads(s)).toHaveLength(count)
    s.time.advance(1)
    await s.flush()
    expect(reads(s)).toHaveLength(count + 1)
  })

  it("does not retry a permanent rejection, and stops retrying when disposed", async () => {
    const s = setup()
    s.model.markRead(mid(7))
    s.endpoint.patch({ settled: [{ tx: reads(s)[0]!.tx, status: "rejected", reason: "invalid" }] })
    await s.flush()
    s.time.advance(10_000)
    await s.flush()
    expect(reads(s)).toHaveLength(1)

    s.model.markRead(mid(8))
    s.endpoint.patch({ settled: [{ tx: reads(s)[1]!.tx, status: "rejected", reason: "unavailable" }] })
    await s.flush()
    s.release()
    s.time.advance(10_000)
    await s.flush()
    expect(reads(s)).toHaveLength(2)
  })
})
