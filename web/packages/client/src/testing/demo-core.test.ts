import {
  rowKey,
  sentMessageRowId,
  type DialogRow,
  type Intent,
  type MessageRow,
  type Patch,
} from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { Log } from "@inline/log"
import { afterEach, describe, expect, it } from "vitest"
import { CoreHost } from "../host/core-host"
import { FakeDisk, TestContext } from "../host/__tests__/fixtures"
import { DEMO_USER_ID } from "./demo-protocol"
import { DemoWorld, memoryWorldStore, type DemoWorldStore } from "./demo-world"
import { useFakeTime, type FakeTime } from "./virtual-clock"

/**
 * The demo core end to end in Node: the real `CoreHost` (Db on in-memory
 * SQLite, realtime client, sync engine, outbox, queries) whose only fake is
 * the wire, a `DemoWorld` holding a seeded `DemoServerModel`.
 */

const me = DEMO_USER_ID as UserID

const quiet = () => new Log("Demo", { sink: false })

type Running = {
  time: FakeTime
  world: DemoWorld
  host: CoreHost
  ui: TestContext
  disk: FakeDisk
}

const running: Running[] = []
let time: FakeTime | undefined

afterEach(async () => {
  for (const entry of running.splice(0)) {
    await settleUntil(entry.host.shutdown())
    await settleUntil(entry.world.dispose())
  }
  time?.dispose()
  time = undefined
})

const clock = () => {
  time ??= useFakeTime({ startMs: Date.UTC(2026, 10, 17, 9) })
  return time
}

/** Await a promise from the core while driving fake time. */
const settleUntil = async <T>(promise: Promise<T>): Promise<T> => {
  let outcome: { value: T } | { error: unknown } | undefined
  promise.then(
    (value) => {
      outcome = { value }
    },
    (error: unknown) => {
      outcome = { error }
    },
  )
  await clock().runUntil(() => outcome != null, { stepMs: 50, maxMs: 120_000 })
  if ("error" in outcome!) throw outcome.error
  return outcome!.value
}

const start = async (
  options: { disk?: FakeDisk; store?: DemoWorldStore; scale?: "small" | "medium" } = {},
): Promise<Running> => {
  const time = clock()
  const disk = options.disk ?? new FakeDisk()
  let host: CoreHost | undefined
  const world = new DemoWorld({
    seed: 7,
    scale: options.scale ?? "small",
    storage: "memory",
    ...(options.store ? { store: options.store } : {}),
    onWake: () => host?.post({ kind: "signal", signal: { kind: "wake" } }),
    logger: quiet(),
  })
  host = new CoreHost({
    buildId: "2026-11-17T00:00:00Z-demo-test",
    openStorage: () => disk.storage(),
    createTransport: () => world.transport,
    realtime: { connection: { backoffDelayMs: () => 500 } },
    logger: quiet(),
  })
  const ui = new TestContext(host)
  ui.post({ kind: "session", action: "start", session: { userId: me, token: "demo" } })
  ui.subscribeTo(1, { kind: "core" })
  ui.subscribeTo(2, { kind: "sidebar", mode: "inbox" })
  const entry = { time, world, host, ui, disk }
  running.push(entry)
  await settleUntil(world.ready)
  return entry
}

const until = (predicate: () => boolean, description: string, maxMs = 60_000) =>
  clock().runUntil(predicate, { stepMs: 50, maxMs, description })

const sidebarRows = (ui: TestContext) => ui.rows(2) as DialogRow[]

const messageRows = (ui: TestContext, sub: number) => ui.rows(sub) as MessageRow[]

const openChat = async (ui: TestContext, sub: number, chatId: ChatID) => {
  ui.subscribeTo(sub, { kind: "chatWindow", chatId, anchor: "latest" })
  await until(
    () => ui.window(sub)?.loading === "none" && ui.list(sub).length > 0,
    `chat ${chatId} window`,
  )
}

const connected = (ui: TestContext) => ui.core(1)?.connection === "connected"

/** Wait until the core has applied everything the server sent (sync idle). */
const synced = async (entry: Running) => {
  await until(() => connected(entry.ui), "connected")
  await settleUntil(entry.host.idle())
  await clock().settle()
}

describe("demo core", () => {
  it("serves the seeded account through the real core: sidebar with unread counts and a chat window", async () => {
    const entry = await start()
    const { ui, world } = entry
    const server = world.server!
    await until(() => ui.core(1)?.phase === "ready" && connected(ui), "ready and connected")
    await until(() => ui.list(2).length > 0, "sidebar rows")
    await synced(entry)

    const rows = sidebarRows(ui)
    // The inbox is the chats the plan opened or pinned, pinned first.
    const inbox = world.demoAccount!.chats.filter((chat) => !chat.archived && (chat.open || chat.pinned))
    expect(rows).toHaveLength(inbox.length)
    expect(rows.filter((row) => row.pinned).map((row) => row.chatId)).toEqual(
      rows.slice(0, rows.filter((row) => row.pinned).length).map((row) => row.chatId),
    )
    for (const row of rows) {
      expect(row.unreadCount).toBe(server.unreadCount(BigInt(row.chatId)))
    }
    expect(rows.some((row) => row.unreadCount > 0)).toBe(true)

    // The busiest inbox chat: its latest page comes from the server, lazily.
    const busiest = inbox.slice().sort((left, right) => right.count - left.count)[0]!
    const chatId = busiest.id.toString() as ChatID
    await openChat(ui, 3, chatId)
    await until(() => ui.list(3).length >= Math.min(50, busiest.count), "latest page")
    const window = messageRows(ui, 3)
    const last = window.at(-1)!
    expect(last.messageId).toBe(String(busiest.count))
    expect(last.text).toBe(world.demoAccount!.messageAt(busiest, BigInt(busiest.count)).text)
    expect(ui.window(3)).toMatchObject({ atLatest: true })
    // Nothing had to be generated in full to get here.
    expect(server.materializedChats()).toBe(0)
  })

  it("pages older history from the lazy server", async () => {
    const entry = await start()
    const { ui, world } = entry
    await synced(entry)
    const busiest = world.demoAccount!.chats.slice().sort((left, right) => right.count - left.count)[0]!
    expect(busiest.count).toBeGreaterThan(150)
    const chatId = busiest.id.toString() as ChatID
    await openChat(ui, 3, chatId)
    await until(() => ui.list(3).length >= 50, "latest page")
    ui.post({ kind: "ensure", sub: 3, range: "older" })
    await until(() => ui.list(3).length >= 100, "older page")
    const ids = messageRows(ui, 3).map((row) => Number(row.messageId))
    // Contiguous on the server (seeded holes skipped), oldest first, ending at the newest message.
    const served = world.server!.lazy(busiest.id)!.idsBefore(undefined, ids.length).map(Number).reverse()
    expect(ids).toEqual(served)
    expect(ids.at(-1)).toBe(busiest.count)
  })

  it("sends a message and sees it confirmed under the same row", async () => {
    const entry = await start()
    const { ui, world } = entry
    await synced(entry)
    const chat = world.demoAccount!.chats.find((candidate) => candidate.open && candidate.count > 0)!
    const chatId = chat.id.toString() as ChatID
    await openChat(ui, 3, chatId)

    const intent: Extract<Intent, { kind: "sendText" }> = {
      kind: "sendText",
      chatId,
      clientKey: "777000111",
      text: "Hello from the demo",
    }
    const key = rowKey("message", sentMessageRowId(chatId, intent.clientKey))
    ui.post({ kind: "intent", tx: "send-1", intent })
    await until(() => ui.result("send-1", "confirmed") != null, "confirmed")
    await until(() => (ui.state.rows.get(key) as MessageRow | undefined)?.state === "sent", "sent row")
    expect(ui.list(3).at(-1)).toBe(key)
    const sent = world.server!.messagesWithRandomId(777000111n)
    expect(sent).toHaveLength(1)
    expect(ui.state.rows.get(key)).toMatchObject({ messageId: sent[0]!.id.toString(), text: intent.text })
  })

  it("receives a simulated incoming message in the open chat and the sidebar", async () => {
    const entry = await start()
    const { ui, world } = entry
    await synced(entry)
    const chat = sidebarRows(ui)[0]!
    await openChat(ui, 3, chat.chatId)
    const before = sidebarRows(ui).find((row) => row.chatId === chat.chatId)!.unreadCount

    const result = await settleUntil(
      world.handle({ kind: "deliver", chatId: chat.chatId, text: "Incoming from the demo" }),
    )
    expect(result.ok).toBe(true)
    const messageId = result.detail!.messageId as MessageID
    const key = rowKey("message", `${chat.chatId}:${messageId}`)
    await until(() => ui.list(3).at(-1) === key, "incoming row at the bottom")
    expect(ui.state.rows.get(key)).toMatchObject({ text: "Incoming from the demo", out: false })
    await until(
      () => sidebarRows(ui).find((row) => row.chatId === chat.chatId)?.unreadCount === before + 1,
      "unread count",
    )
  })

  it("streams an agent message: each update is a patch touching that one row", async () => {
    const entry = await start()
    const { ui, world } = entry
    await synced(entry)
    const chat = sidebarRows(ui)[0]!
    await openChat(ui, 3, chat.chatId)

    const result = await settleUntil(
      world.handle({
        kind: "agent",
        action: "start",
        chatId: chat.chatId,
        updatesPerSecond: 50,
        durationMs: 1_000,
      }),
    )
    expect(result.ok).toBe(true)
    const messageId = result.detail!.messageId!
    const key = rowKey("message", `${chat.chatId}:${messageId}`)
    await until(() => ui.list(3).includes(key), "agent row")
    const firstEditPatch = ui.patches.length
    await until(() => world.status().agent?.running === false, "agent finished", 10_000)
    await synced(entry)

    const final = world.server!.chatState(BigInt(chat.chatId)).messages.find(
      (message) => message.id === BigInt(messageId),
    )!
    expect((ui.state.rows.get(key) as MessageRow).text).toBe(final.text)
    expect(world.status().agent!.edits).toBeGreaterThanOrEqual(40)

    const touching = ui.patches
      .slice(firstEditPatch)
      .filter((patch: Patch) =>
        patch.rows.some((change) => change.op === "upsert" && rowKey("message", change.row.id) === key),
      )
    // Every edit reached the UI as its own small patch (commits in one task coalesce).
    expect(touching.length).toBeGreaterThanOrEqual(world.status().agent!.edits * 0.8)
    for (const patch of touching) {
      expect(patch.rows).toHaveLength(1)
      expect(patch.lists).toEqual([])
    }
  })

  it("goes offline and comes back: a send waits, then confirms", async () => {
    const entry = await start()
    const { ui, world } = entry
    await synced(entry)
    const chat = sidebarRows(ui)[0]!
    await openChat(ui, 3, chat.chatId)

    await settleUntil(world.handle({ kind: "network", online: false }))
    await until(() => !connected(ui), "disconnected")
    const intent: Extract<Intent, { kind: "sendText" }> = {
      kind: "sendText",
      chatId: chat.chatId,
      clientKey: "777000222",
      text: "Sent while offline",
    }
    ui.post({ kind: "intent", tx: "offline-1", intent })
    await until(() => ui.result("offline-1", "accepted") != null, "accepted offline")
    await clock().advance(5_000)
    await clock().settle()
    expect(ui.result("offline-1", "confirmed")).toBeUndefined()
    expect(connected(ui)).toBe(false)
    expect(world.status().connection).not.toBe("connected")

    await settleUntil(world.handle({ kind: "network", online: true }))
    await until(() => connected(ui), "reconnected")
    await until(() => ui.result("offline-1", "confirmed") != null, "confirmed after reconnect")
    expect(world.server!.messagesWithRandomId(777000222n)).toHaveLength(1)
  })

  it("delivers with latency and loss on acknowledgements, and other members react, edit and delete", async () => {
    const entry = await start()
    const { ui, world } = entry
    await synced(entry)
    const chat = sidebarRows(ui)[0]!
    await openChat(ui, 3, chat.chatId)

    await settleUntil(world.handle({ kind: "faults", latencyMs: 400, lossRate: 0 }))
    ui.post({
      kind: "intent",
      tx: "slow-1",
      intent: { kind: "sendText", chatId: chat.chatId, clientKey: "777000333", text: "Slow ack" },
    })
    await until(() => ui.result("slow-1", "accepted") != null, "accepted")
    const acceptedAt = clock().now()
    await until(() => ui.result("slow-1", "confirmed") != null, "confirmed with latency")
    expect(clock().now() - acceptedAt).toBeGreaterThanOrEqual(400)
    await settleUntil(world.handle({ kind: "faults", latencyMs: 0, lossRate: 0 }))

    const incoming = await settleUntil(world.handle({ kind: "deliver", chatId: chat.chatId, text: "Target" }))
    const target = incoming.detail!.messageId!
    const key = rowKey("message", `${chat.chatId}:${target}`)
    await until(() => ui.list(3).includes(key), "target row")

    await settleUntil(world.handle({ kind: "otherUser", action: "react", chatId: chat.chatId, messageId: target, emoji: "🎉" }))
    await until(
      () => (ui.state.rows.get(key) as MessageRow | undefined)?.reactions?.some((reaction) => reaction.emoji === "🎉") === true,
      "reaction",
    )
    await settleUntil(world.handle({ kind: "otherUser", action: "edit", chatId: chat.chatId, messageId: target, text: "Target, edited" }))
    await until(() => (ui.state.rows.get(key) as MessageRow | undefined)?.text === "Target, edited", "edit")
    await settleUntil(world.handle({ kind: "otherUser", action: "delete", chatId: chat.chatId, messageId: target }))
    await until(() => !ui.list(3).includes(key), "delete")

    await settleUntil(world.handle({ kind: "otherUser", action: "read", chatId: chat.chatId }))
    await until(
      () => sidebarRows(ui).find((row) => row.chatId === chat.chatId)?.unreadCount === 0,
      "read on another device",
    )
  })

  it("keeps the server's changes across a restart, and new events still arrive", async () => {
    const store = memoryWorldStore()
    const disk = new FakeDisk()
    const first = await start({ store, disk })
    await synced(first)
    const chat = sidebarRows(first.ui)[0]!
    await openChat(first.ui, 3, chat.chatId)
    const delivered = await settleUntil(
      first.world.handle({ kind: "deliver", chatId: chat.chatId, text: "Before the reload" }),
    )
    const beforeKey = rowKey("message", `${chat.chatId}:${delivered.detail!.messageId}`)
    await until(() => first.ui.list(3).includes(beforeKey), "delivered before reload")

    // A reload: the worker goes away; the replica and the saved server state stay.
    running.splice(running.indexOf(first), 1)
    await settleUntil(first.host.shutdown())
    await settleUntil(first.world.dispose())
    expect(store.saved?.chats.some((saved) => saved.id === chat.chatId)).toBe(true)

    const second = await start({ store, disk })
    await synced(second)
    await openChat(second.ui, 3, chat.chatId)
    expect(second.ui.list(3)).toContain(beforeKey)
    const after = await settleUntil(
      second.world.handle({ kind: "deliver", chatId: chat.chatId, text: "After the reload" }),
    )
    // A new ID and sequence: the replica does not take it for a duplicate.
    expect(BigInt(after.detail!.messageId!)).toBeGreaterThan(BigInt(delivered.detail!.messageId!))
    const afterKey = rowKey("message", `${chat.chatId}:${after.detail!.messageId}`)
    await until(() => second.ui.list(3).includes(afterKey), "delivered after reload")
    expect(second.ui.list(3)).toContain(beforeKey)
  })

  it("survives a crash between saves: events after the last save are never reused", async () => {
    const store = memoryWorldStore()
    const disk = new FakeDisk()
    const first = await start({ store, disk })
    await synced(first)
    const chat = sidebarRows(first.ui)[0]!
    await openChat(first.ui, 3, chat.chatId)
    const saved = await settleUntil(first.world.handle({ kind: "deliver", chatId: chat.chatId, text: "Saved" }))
    await clock().advance(2_000)
    await clock().settle()
    expect(store.saved?.chats.find((entry) => entry.id === chat.chatId)?.messages.map((message) => message.text)).toContain("Saved")

    // From here the server's saves are lost, as if the worker died first.
    const frozen = structuredClone(store.saved)
    const unsaved = await settleUntil(first.world.handle({ kind: "deliver", chatId: chat.chatId, text: "Not saved" }))
    const unsavedKey = rowKey("message", `${chat.chatId}:${unsaved.detail!.messageId}`)
    await until(() => first.ui.list(3).includes(unsavedKey), "unsaved message reached the replica")
    running.splice(running.indexOf(first), 1)
    await settleUntil(first.host.shutdown())
    await settleUntil(first.world.dispose())
    store.saved = frozen

    const second = await start({ store, disk })
    await synced(second)
    await openChat(second.ui, 3, chat.chatId)
    const next = await settleUntil(second.world.handle({ kind: "deliver", chatId: chat.chatId, text: "After the crash" }))
    expect(BigInt(next.detail!.messageId!)).toBeGreaterThan(BigInt(unsaved.detail!.messageId!))
    const nextKey = rowKey("message", `${chat.chatId}:${next.detail!.messageId}`)
    await until(() => second.ui.list(3).includes(nextKey), "message after the crash arrives")
    expect(second.ui.state.rows.get(nextKey)).toMatchObject({ text: "After the crash" })
    const savedKey = rowKey("message", `${chat.chatId}:${saved.detail!.messageId}`)
    expect(second.ui.list(3)).toContain(savedKey)
    // The window follows the server, which lost the unsaved message.
    expect(second.ui.list(3)).not.toContain(unsavedKey)
  })

  it("survives a lost save: the server starts past anything the replica saw", async () => {
    const store = memoryWorldStore()
    const disk = new FakeDisk()
    const first = await start({ store, disk })
    await synced(first)
    const chat = sidebarRows(first.ui)[0]!
    await openChat(first.ui, 3, chat.chatId)
    for (let count = 0; count < 3; count += 1) {
      await settleUntil(first.world.handle({ kind: "deliver", chatId: chat.chatId }))
    }
    running.splice(running.indexOf(first), 1)
    await settleUntil(first.host.shutdown())
    await settleUntil(first.world.dispose())
    await store.erase()
    // Reloaded a minute later.
    await clock().advance(60_000)

    const second = await start({ store, disk })
    await synced(second)
    await openChat(second.ui, 3, chat.chatId)
    const next = await settleUntil(second.world.handle({ kind: "deliver", chatId: chat.chatId, text: "After a lost save" }))
    const nextKey = rowKey("message", `${chat.chatId}:${next.detail!.messageId}`)
    await until(() => second.ui.list(3).includes(nextKey), "message after a lost save arrives")
  })
})
