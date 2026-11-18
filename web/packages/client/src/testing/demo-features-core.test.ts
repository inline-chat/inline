import {
  newAttachmentId,
  newClientKey,
  rowKey,
  sentMessageRowId,
  type ComposeResource,
  type DialogRow,
  type MediaResource,
  type MemberRow,
  type MessageRow,
  type RemoteSearchResource,
} from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { Log } from "@inline/log"
import { afterEach, describe, expect, it } from "vitest"
import { CoreHost } from "../host/core-host"
import { FakeDisk, TestContext } from "../host/__tests__/fixtures"
import { demoPng } from "./demo-bytes"
import { extrasOf } from "./demo-content"
import { DEMO_DELIVER_CONTENT, DEMO_USER_ID } from "./demo-protocol"
import { DemoWorld, memoryWorldStore, type DemoWorldStore } from "./demo-world"
import { useFakeTime, type FakeTime } from "./virtual-clock"

/**
 * The demo's new features end to end in Node: the real `CoreHost` (replica
 * on in-memory SQLite, realtime client, sync, outbox, media core, queries)
 * against a `DemoWorld`. One test per area: a photo's bytes through the media
 * pipeline, an upload and its send, typing, a participant added, a pin kept
 * across a reload, server search past the local window. The media core's
 * `fetch` is a spy that must never be called: every byte stays in the world.
 */

const me = DEMO_USER_ID as UserID
const quiet = () => new Log("Demo", { sink: false })

type Running = { world: DemoWorld; host: CoreHost; ui: TestContext; disk: FakeDisk; fetches: string[] }

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

const until = (predicate: () => boolean, description: string, maxMs = 60_000) =>
  clock().runUntil(predicate, { stepMs: 50, maxMs, description })

const start = async (options: { disk?: FakeDisk; store?: DemoWorldStore } = {}): Promise<Running> => {
  clock()
  const disk = options.disk ?? new FakeDisk()
  const fetches: string[] = []
  let host: CoreHost | undefined
  const world = new DemoWorld({
    seed: 7,
    scale: "small",
    storage: "memory",
    ...(options.store ? { store: options.store } : {}),
    onWake: () => host?.post({ kind: "signal", signal: { kind: "wake" } }),
    logger: quiet(),
  })
  host = new CoreHost({
    buildId: "2026-11-17T00:00:00Z-demo-features",
    openStorage: () => disk.storage(),
    createTransport: () => world.transport,
    realtime: { connection: { backoffDelayMs: () => 500 } },
    media: {
      fetch: async (input) => {
        fetches.push(String(input))
        throw new TypeError("no network in the demo")
      },
    },
    logger: quiet(),
  })
  const ui = new TestContext(host)
  ui.post({ kind: "session", action: "start", session: { userId: me, token: "demo" } })
  ui.subscribeTo(1, { kind: "core" })
  ui.subscribeTo(2, { kind: "sidebar", mode: "inbox" })
  const entry = { world, host, ui, disk, fetches }
  running.push(entry)
  await settleUntil(world.ready)
  await until(() => ui.core(1)?.connection === "connected", "connected")
  await settleUntil(host.idle())
  await clock().settle()
  return entry
}

const resource = <T>(ui: TestContext, sub: number) => ui.state.resources.get(sub) as T | undefined

const openChat = async (ui: TestContext, sub: number, chatId: ChatID) => {
  ui.subscribeTo(sub, { kind: "chatWindow", chatId, anchor: "latest" })
  await until(() => ui.window(sub)?.loading === "none" && ui.list(sub).length > 0, `chat ${chatId} window`)
}

describe("demo features through the real core", () => {
  it("delivers a photo whose preview is in the row and whose bytes come through the media pipeline", async () => {
    const { ui, world, fetches } = await start()
    const chatId = world.status().recentChatIds[0]! as ChatID
    await openChat(ui, 3, chatId)
    const delivered = await settleUntil(world.handle({ kind: "deliver", chatId, content: "tallPhoto" }))
    const messageId = delivered.detail!.messageId! as MessageID
    const key = rowKey("message", `${chatId}:${messageId}`)
    await until(() => ui.list(3).includes(key), "photo row")
    const row = ui.state.rows.get(key) as MessageRow
    const media = row.media
    if (media?.kind !== "photo") throw new Error("expected a photo row")
    // First paint: the stripped preview is in the row; sizes say how big each file is.
    expect(media.photo.stripped?.[0]).toBe(1)
    const size = media.photo.sizes.find((size) => size.type === "c")!
    expect(size.height / size.width).toBeGreaterThan(3)
    expect(size.size).toBeGreaterThan(0)

    ui.subscribeTo(4, { kind: "media", media: { kind: "message", chatId, messageId, size: "c" } })
    await until(() => resource<MediaResource>(ui, 4)?.state === "ready", "photo bytes")
    const ready = resource<MediaResource>(ui, 4)!
    expect(ready.size).toBe(size.size)
    const bytes = new Uint8Array(await ready.blob!.arrayBuffer())
    expect(Array.from(bytes.subarray(1, 4), (code) => String.fromCharCode(code)).join("")).toBe("PNG")
    expect(world.server!.transfers.partsServed).toBeGreaterThan(0)
    expect(fetches).toEqual([])
  })

  it("uploads an attachment with progress and latency, then sends it once with its media", async () => {
    const { ui, world, fetches } = await start()
    const chatId = world.status().recentChatIds[0]! as ChatID
    await openChat(ui, 3, chatId)
    const attachmentId = newAttachmentId()
    const png = demoPng(5, 900, 600)
    ui.post({
      kind: "intent",
      tx: "attach",
      intent: {
        kind: "attachFile",
        attachmentId,
        file: new Blob([png as Uint8Array<ArrayBuffer>], { type: "image/png" }),
        fileName: "chart.png",
        mimeType: "image/png",
        width: 900,
        height: 600,
      },
    })
    await until(() => ui.result("attach", "confirmed") != null, "attached")
    ui.subscribeTo(5, { kind: "media", media: { kind: "attachment", attachmentId } })
    const clientKey = newClientKey()
    ui.post({ kind: "intent", tx: "send", intent: { kind: "sendMedia", chatId, clientKey, attachmentId, text: "the chart" } })
    await until(() => ui.result("send", "accepted") != null, "send accepted")
    const progress: string[] = []
    await until(() => {
      const upload = resource<MediaResource>(ui, 5)?.upload
      if (upload) progress.push(upload.state)
      return ui.result("send", "confirmed") != null
    }, "send confirmed")
    expect(progress).toContain("uploading")
    expect(world.status().media.uploadsCompleted).toBe(1)
    const sent = world.server!.messagesWithRandomId(BigInt(clientKey))
    expect(sent).toHaveLength(1)
    const extras = extrasOf(sent[0])
    expect(extras?.media?.kind === "wire" && extras.media.media.media.oneofKind).toBe("photo")
    const key = rowKey("message", sentMessageRowId(chatId, clientKey))
    await until(() => (ui.state.rows.get(key) as MessageRow | undefined)?.media?.kind === "photo", "sent row with its photo")
    const row = ui.state.rows.get(key) as MessageRow
    expect(row).toMatchObject({ state: "sent", messageId: sent[0]!.id.toString(), text: "the chart" })
    expect(fetches).toEqual([])
  })

  it("shows another member typing in a subscribed chat until it stops, and answers the account's own typing", async () => {
    const { ui, world } = await start()
    const chatId = world.status().recentChatIds[0]! as ChatID
    ui.subscribeTo(6, { kind: "composeActions", chatId })
    const typing = await settleUntil(world.handle({ kind: "typing", chatId, ms: 8_000 }))
    const userId = typing.detail!.userId!
    await until(
      () => resource<ComposeResource>(ui, 6)?.activities.some((activity) => activity.userId === userId && activity.action === "typing") === true,
      "typing shown",
    )
    // Refreshed every 3 s, so it outlives the 6 s expiry; then it stops.
    await clock().advance(7_000)
    expect(resource<ComposeResource>(ui, 6)?.activities).toHaveLength(1)
    await until(() => resource<ComposeResource>(ui, 6)?.activities.length === 0, "typing stopped")
    expect(world.status().typing).toEqual([])

    ui.post({ kind: "intent", tx: "compose", intent: { kind: "composeAction", chatId, action: "typing" } })
    await until(() => world.status().ownCompose?.chatId === chatId, "own compose action reached the server")
  })

  it("adds a person from the space to a private thread", async () => {
    const { ui, world } = await start()
    const samples = world.samples()
    const thread = samples.privateThread!
    expect(thread.outsiderUserId).toBeDefined()
    const chatId = thread.chatId as ChatID
    // The thread is open and synced (a message arrived, so the replica's
    // cursor is the server's), so the removal below arrives live.
    await openChat(ui, 8, chatId)
    const hello = await settleUntil(world.handle({ kind: "deliver", chatId }))
    await until(() => ui.list(8).includes(rowKey("message", `${chatId}:${hello.detail!.messageId}`)), "chat synced")
    ui.subscribeTo(7, { kind: "chatParticipants", chatId })
    await until(() => ui.list(7).length > 0, "participants")
    ui.post({
      kind: "intent",
      tx: "add",
      intent: { kind: "addChatParticipants", chatId, userIds: [thread.outsiderUserId as UserID] },
    })
    await until(() => ui.result("add", "confirmed") != null, "added")
    await until(
      () => (ui.rows(7) as MemberRow[]).some((member) => member.kind === "member" && member.userId === thread.outsiderUserId),
      "new member listed",
    )
    expect(world.server!.participantsOf(BigInt(chatId)).map((entry) => entry.userId.toString())).toContain(thread.outsiderUserId)
    // A member elsewhere removes them again: the list follows.
    await settleUntil(world.handle({ kind: "participants", action: "remove", chatId, userId: thread.outsiderUserId! }))
    await until(
      () => !(ui.rows(7) as MemberRow[]).some((member) => member.userId === thread.outsiderUserId),
      "member removed",
    )
  })

  it("keeps a pin and an archive made on two devices across a reload", async () => {
    const store = memoryWorldStore()
    const disk = new FakeDisk()
    const first = await start({ store, disk })
    const rows = () => first.ui.rows(2) as DialogRow[]
    const target = rows().find((row) => !row.pinned)!
    first.ui.post({ kind: "intent", tx: "pin", intent: { kind: "setDialogPinned", chatId: target.chatId, pinned: true } })
    await until(() => first.ui.result("pin", "confirmed") != null, "pinned")
    const archived = rows().find((row) => !row.pinned && row.chatId !== target.chatId)!
    await settleUntil(first.world.handle({ kind: "otherDevice", action: "archive", chatId: archived.chatId }))
    await until(() => !rows().some((row) => row.chatId === archived.chatId), "archived on the other device")
    expect(rows().find((row) => row.chatId === target.chatId)?.pinned).toBe(true)

    running.splice(running.indexOf(first), 1)
    await settleUntil(first.host.shutdown())
    await settleUntil(first.world.dispose())

    // A fresh replica: everything comes from the server's saved state.
    const second = await start({ store })
    await until(() => second.ui.list(2).length > 0, "sidebar after reload")
    const after = second.ui.rows(2) as DialogRow[]
    expect(after.find((row) => row.chatId === target.chatId)?.pinned).toBe(true)
    expect(after.some((row) => row.chatId === archived.chatId)).toBe(false)
  })

  it("finds on the server a message older than the local window", async () => {
    const { ui, world } = await start()
    const search = world.samples().search!
    expect(search).toBeDefined()
    const chatId = search.chatId as ChatID
    await openChat(ui, 3, chatId)
    expect(ui.list(3)).not.toContain(rowKey("message", `${chatId}:${search.messageId}`))
    const hits: string[] = []
    let offsetId: MessageID | undefined
    for (let page = 0; page < 20 && !hits.includes(search.messageId); page += 1) {
      const sub = 10 + page
      ui.subscribeTo(sub, {
        kind: "searchServerMessages",
        request: { chatId, query: search.query, limit: 50, ...(offsetId ? { offsetId } : {}) },
      })
      await until(() => resource<RemoteSearchResource>(ui, sub)?.status === "done", "search page")
      const done = resource<RemoteSearchResource>(ui, sub)!
      if (done.status !== "done" || done.result.kind !== "messages") throw new Error("expected hits")
      hits.push(...done.result.hits.map((hit) => hit.messageId))
      if (!done.result.nextOffsetId) break
      offsetId = done.result.nextOffsetId
    }
    expect(hits).toContain(search.messageId)
  })

  it("delivers every kind of content as rows, and the controls report in the status", async () => {
    const { ui, world, fetches } = await start()
    const chatId = world.status().recentChatIds[1]! as ChatID
    await openChat(ui, 3, chatId)
    for (const content of DEMO_DELIVER_CONTENT) {
      const result = await settleUntil(world.handle({ kind: "deliver", chatId, content }))
      expect(result.ok).toBe(true)
      const key = rowKey("message", `${chatId}:${result.detail!.messageId}`)
      await until(() => ui.list(3).includes(key), `${content} row`)
      const row = ui.state.rows.get(key) as MessageRow
      if (content === "photo" || content === "tallPhoto" || content === "widePhoto" || content === "squarePhoto") {
        expect(row.media?.kind).toBe("photo")
      } else if (content === "video" || content === "document" || content === "voice") {
        expect(row.media?.kind).toBe(content)
      } else if (content === "entities" || content === "code" || content === "mention") {
        expect(row.entities?.length).toBeGreaterThan(0)
      } else if (content === "reply") {
        expect(row.replyToMessageId).toBeDefined()
      }
    }
    await settleUntil(world.handle({ kind: "media", uploadLatencyMs: 900, processingRounds: 2, inlineData: true }))
    await settleUntil(world.handle({ kind: "actions", failNext: 2, failureRate: 0.1 }))
    await settleUntil(world.handle({ kind: "activity", level: "busy" }))
    await clock().advance(20_000)
    const status = world.status()
    expect(status.media).toMatchObject({ uploadLatencyMs: 900, processingRounds: 2, inlineData: true })
    expect(status.actions).toMatchObject({ failNext: 2, failureRate: 0.1 })
    expect(status.activity).toBe("busy")
    expect(status.samples.photo ?? status.samples.tallPhoto ?? status.samples.widePhoto).toBeDefined()
    expect(status.samples.directChatId).toBeDefined()
    await settleUntil(world.handle({ kind: "activity", level: "off" }))
    expect(fetches).toEqual([])
  })
})
