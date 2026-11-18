import type { QueryDescriptor } from "@inline/core-protocol"
import { describe, expect, it } from "vitest"
import { createScheduler, manualTime } from "../schedule"
import { effect } from "../signals"
import { chatId, echoRow, message, sendText } from "../testing/rows"
import { keyOf, scriptedEndpoint } from "../testing/scripted-endpoint"
import { createStoreClient, txIdAllocator } from "./client"

const setup = () => {
  const time = manualTime()
  const scheduler = createScheduler({ clock: time, frames: time.frames, idleSource: time.idleSource })
  const endpoint = scriptedEndpoint()
  const client = createStoreClient({ endpoint, scheduler, newTxId: txIdAllocator("ctx") })
  return { time, scheduler, endpoint, client }
}

const chatWindow: QueryDescriptor = { kind: "chatWindow", chatId: chatId(1), anchor: "latest" }

describe("subscribe", () => {
  it("allocates sub IDs, posts the command and exposes the list and resource", () => {
    const { endpoint, client, time } = setup()
    const first = client.subscribe(chatWindow)
    const second = client.subscribe({ kind: "core" })
    expect(first.sub).not.toBe(second.sub)
    expect(endpoint.commands("subscribe")).toEqual([
      { kind: "subscribe", sub: first.sub, query: chatWindow },
      { kind: "subscribe", sub: second.sub, query: { kind: "core" } },
    ])
    const row = message(1, 1)
    endpoint.patch({ rows: [{ op: "upsert", row }], lists: [{ sub: first.sub, op: "replace", keys: [keyOf(row)] }] })
    expect(first.list.peek()).toEqual([])
    time.frame()
    expect(first.list.peek()).toEqual([keyOf(row)])
  })

  it("posts unsubscribe once and forgets the subscription", () => {
    const { endpoint, client } = setup()
    const handle = client.subscribe(chatWindow)
    handle.unsubscribe()
    handle.unsubscribe()
    expect(endpoint.commands("unsubscribe")).toEqual([{ kind: "unsubscribe", sub: handle.sub }])
    expect(client.store.hasSub(handle.sub)).toBe(false)
    handle.ensure("older")
    expect(endpoint.commands("ensure")).toEqual([])
  })

  it("forwards ensure for a live subscription", () => {
    const { endpoint, client } = setup()
    const handle = client.subscribe(chatWindow)
    handle.ensure("older")
    expect(endpoint.commands("ensure")).toEqual([{ kind: "ensure", sub: handle.sub, range: "older" }])
  })
})

describe("frame lane delivery", () => {
  it("applies every patch that arrived within a frame in one batch", () => {
    const { endpoint, client, time } = setup()
    const handle = client.subscribe(chatWindow)
    const seen: number[] = []
    effect(() => {
      seen.push(handle.list.get().length)
    })
    for (let i = 1; i <= 5; i++) {
      endpoint.patch({ lists: [{ sub: handle.sub, op: "splice", index: i - 1, remove: 0, insert: [keyOf(message(1, i))] }] })
    }
    time.frame()
    expect(seen).toEqual([0, 5])
    expect(client.store.revision.peek()).toBe(5)
  })
})

describe("gaps", () => {
  it("refuses a patch with a wrong base, requests a resync and drops patches until the snapshot", () => {
    const { endpoint, client, time } = setup()
    const handle = client.subscribe(chatWindow)
    const a = message(1, 1)
    endpoint.patch({ rows: [{ op: "upsert", row: a }], lists: [{ sub: handle.sub, op: "replace", keys: [keyOf(a)] }] })
    time.frame()
    expect(client.store.revision.peek()).toBe(1)

    // Revision 2 was lost; the next patch is based on 2.
    const b = message(1, 2)
    endpoint.patch({ base: 2, revision: 3, rows: [{ op: "upsert", row: b }] })
    endpoint.patch({ base: 3, revision: 4, rows: [{ op: "upsert", row: message(1, 3) }] })
    time.frame()
    expect(client.store.peekRow(keyOf(b))).toBeUndefined()
    expect(client.store.revision.peek()).toBe(1)
    expect(endpoint.commands("resync")).toEqual([{ kind: "resync" }])
    expect(client.resyncing()).toBe(true)

    // More patches on the old chain are dropped without asking again.
    endpoint.patch({ base: 4, revision: 5 })
    time.frame()
    expect(endpoint.commands("resync")).toHaveLength(1)

    endpoint.deliver({
      kind: "snapshot",
      snapshot: { revision: 5, rows: [a, b], lists: [{ sub: handle.sub, keys: [keyOf(a), keyOf(b)] }], resources: [] },
    })
    time.frame()
    expect(client.resyncing()).toBe(false)
    expect(handle.list.peek()).toEqual([keyOf(a), keyOf(b)])
    expect(client.store.peekRow(keyOf(a))).toBe(a)

    endpoint.patch({ base: 5, revision: 6, rows: [{ op: "upsert", row: message(1, 3) }] })
    time.frame()
    expect(client.store.revision.peek()).toBe(6)
  })
})

describe("intents", () => {
  it("installs the echo in the sync lane, before the command is posted, and resolves on settle", async () => {
    const { endpoint, client, time } = setup()
    const handle = client.subscribe(chatWindow)
    const intent = sendText(1, "77", "hi")
    const echo = echoRow(intent)
    let readBeforePost: unknown
    const post = endpoint.post
    endpoint.post = (command) => {
      if (command.kind === "intent") readBeforePost = client.store.peekRow(keyOf(echo))
      post(command)
    }

    const sent = client.intent(intent, [{ row: echo, appendTo: [handle.sub] }])
    // Readable in the same task it was written.
    expect(client.store.peekRow(keyOf(echo))).toBe(echo)
    expect(handle.list.peek()).toEqual([keyOf(echo)])
    expect(readBeforePost).toBe(echo)
    expect(endpoint.commands("intent")).toEqual([{ kind: "intent", tx: sent.tx, intent }])
    expect(sent.tx).toBe("ctx-1")

    endpoint.patch({
      rows: [{ op: "upsert", row: { ...echo } }],
      lists: [{ sub: handle.sub, op: "replace", keys: [keyOf(echo)] }],
      settled: [{ tx: sent.tx, status: "accepted", rows: [keyOf(echo)] }],
    })
    time.frame()
    await expect(sent).resolves.toEqual({ tx: sent.tx, status: "accepted", rows: [keyOf(echo)] })
    expect(client.store.hasOverlay(keyOf(echo))).toBe(false)
    expect(client.store.peekRow(keyOf(echo))).toBe(echo)
  })

  it("removes the echo when the core rejects the intent", async () => {
    const { endpoint, client, time } = setup()
    const handle = client.subscribe(chatWindow)
    const intent = sendText(1, "78", "too big")
    const echo = echoRow(intent)
    const sent = client.intent(intent, [{ row: echo, appendTo: [handle.sub] }])
    endpoint.patch({ settled: [{ tx: sent.tx, status: "rejected", reason: "storageFull" }] })
    time.frame()
    const result = await sent
    expect(result.status).toBe("rejected")
    expect(handle.list.peek()).toEqual([])
  })

  it("allocates distinct transaction IDs", () => {
    const { client } = setup()
    const a = client.intent({ kind: "markRead", chatId: chatId(1), maxId: "1" as never })
    const b = client.intent({ kind: "markRead", chatId: chatId(1), maxId: "2" as never })
    expect(a.tx).not.toBe(b.tx)
    const random = txIdAllocator()
    expect(random()).not.toBe(txIdAllocator()())
  })
})

describe("boot snapshot data", () => {
  it("exports subscriptions with their queries and restores them under new sub IDs", () => {
    const { endpoint, client, time } = setup()
    const handle = client.subscribe(chatWindow)
    const a = message(1, 1)
    endpoint.patch({ rows: [{ op: "upsert", row: a }], lists: [{ sub: handle.sub, op: "replace", keys: [keyOf(a)] }] })
    time.frame()
    const data = JSON.parse(JSON.stringify(client.exportSubscriptions([handle])))

    const next = setup()
    next.client.subscribe({ kind: "core" })
    const [restored] = next.client.restore(data)
    expect(restored).toBeDefined()
    expect(restored!.list.peek()).toEqual([keyOf(a)])
    expect(next.client.store.peekRow(keyOf(a))).toEqual(a)
    expect(next.endpoint.commands("subscribe").at(-1)).toEqual({ kind: "subscribe", sub: restored!.sub, query: chatWindow })
    // The core's first snapshot replaces the provisional state.
    next.endpoint.deliver({ kind: "snapshot", snapshot: { revision: 1, rows: [], lists: [{ sub: restored!.sub, keys: [] }], resources: [] } })
    next.time.frame()
    expect(restored!.list.peek()).toEqual([])
  })
})

describe("dispose", () => {
  it("stops listening and rejects pending intents", async () => {
    const { endpoint, client, time } = setup()
    const handle = client.subscribe(chatWindow)
    const sent = client.intent(sendText(1, "1", "x"))
    client.dispose()
    endpoint.patch({ lists: [{ sub: handle.sub, op: "replace", keys: [keyOf(message(1, 1))] }] })
    time.frame()
    await expect(sent).rejects.toThrow("disposed")
  })

  it("sweeps unobserved row signals in the idle lane after an unsubscribe", () => {
    const { endpoint, client, time } = setup()
    const handle = client.subscribe(chatWindow)
    const a = message(1, 1)
    endpoint.patch({ rows: [{ op: "upsert", row: a }] })
    time.frame()
    effect(() => {
      client.store.rowByKey(keyOf(a)).get()
    })()
    expect(client.store.stats().signals).toBe(1)
    handle.unsubscribe()
    time.idle()
    expect(client.store.stats().signals).toBe(0)
  })
})
