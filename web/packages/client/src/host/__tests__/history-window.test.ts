import { ServerProtocolMessage, type ClientMessage } from "@inline-chat/protocol/core"
import type { Command, MessageRow } from "@inline/core-protocol"
import { chatId, dialogId, messageId, userId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { coverageModelRanges, HISTORY_TOP } from "../../database/history-coverage"
import { DbObjectKind, messageKey, type DbModel } from "../../database/models"
import { CoreHost } from "../core-host"
import { FakeDisk, me, newMessageUpdate, ScriptedTransport, TestContext } from "./fixtures"

const thread = chatId(600)
const peer = userId(8)

const row = (id: number): DbModel => ({
  kind: DbObjectKind.Message,
  id: messageKey(thread, messageId(id)),
  messageId: messageId(id),
  chatId: thread,
  fromId: peer,
  message: `m${id}`,
  date: 1_000 + id,
})

const wire = (id: number) => ({
  id: BigInt(id),
  chatId: 600n,
  fromId: 8n,
  out: false,
  message: `m${id}`,
  date: BigInt(1_000 + id),
})

const ids = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, i) => from + i)

/**
 * Rows 1..79 and 86..100 are stored; 80..85 exist on the server but not on
 * the device. Coverage certifies [1, 79] and [86, top], so 80..85 is a hole.
 */
const seed = (): DbModel[] => [
  { kind: DbObjectKind.User, id: me, firstName: "Mo" },
  { kind: DbObjectKind.User, id: peer, firstName: "Dena" },
  { kind: DbObjectKind.Chat, id: thread, title: "Design", lastMsgId: messageId(100), date: 1_100 },
  {
    kind: DbObjectKind.Dialog,
    id: dialogId(-600),
    chatId: thread,
    peerThreadId: thread,
    open: true,
    order: "a",
    readMaxId: messageId(100),
  },
  {
    kind: DbObjectKind.HistoryCoverage,
    id: thread,
    ranges: coverageModelRanges([
      [1n, 79n],
      [86n, HISTORY_TOP],
    ]),
  },
  ...ids(1, 79).map(row),
  ...ids(86, 100).map(row),
]

const hosts: CoreHost[] = []

afterEach(async () => {
  await Promise.all(hosts.splice(0).map((host) => host.shutdown()))
})

const start = async (pageSize = 20, backoffDelayMs?: () => number) => {
  const disk = new FakeDisk()
  await disk.seed(seed())
  const transport = new ScriptedTransport()
  const host = new CoreHost({
    pageSize,
    buildId: "2026-11-17T00:00:00Z-test",
    openStorage: () => disk.storage(),
    createTransport: () => transport,
    realtime: { sync: false, ...(backoffDelayMs ? { connection: { backoffDelayMs } } : {}) },
    now: () => 1_000_000,
  })
  hosts.push(host)
  const ui = new TestContext(host)
  ui.post({ kind: "session", action: "start", session: { userId: me, token: "token" } })
  ui.subscribeTo(1, { kind: "core" })
  await ui.until(() => ui.core(1)?.phase === "ready", "ready")
  await transport.open()
  await ui.until(() => ui.core(1)?.connection === "connected", "connected")
  ui.subscribeTo(2, { kind: "chatWindow", chatId: thread, anchor: "latest" })
  return { host, transport, ui }
}

const texts = (ui: TestContext, sub: number) =>
  ui.rows(sub).flatMap((value) => (value.kind === "message" ? [(value as MessageRow).text] : []))

const historyRequest = (where: (input: { beforeId?: bigint; afterId?: bigint }) => boolean) =>
  (message: ClientMessage) =>
    message.body.oneofKind === "rpcCall" &&
    message.body.rpcCall.input.oneofKind === "getChatHistory" &&
    where(message.body.rpcCall.input.getChatHistory)

describe("invariant 5: chat windows follow certified history", () => {
  it("invariant 5: takes its edges from coverage and never stitches a page across a hole", async () => {
    const { host, transport, ui } = await start()

    // The latest local page stops at the hole: 86..100, not 75..79 + 86..100.
    await ui.until(() => ui.list(2).length === 15, "latest certified run")
    expect(texts(ui, 2).at(0)).toBe("m86")
    expect(ui.window(2)).toMatchObject({ hasOlder: true, atLatest: true, hasNewer: false })
    expect((ui.window(2) as { certifiedThrough?: string }).certifiedThrough).toBe("100")

    // Paging older crosses the hole, so it goes to the server, not to 60..79.
    ui.post({ kind: "ensure", sub: 2, range: "older" })
    const older = await transport.rpc("getChatHistory", historyRequest((input) => input.beforeId === 86n))
    await transport.reply(older, {
      oneofKind: "getChatHistory",
      getChatHistory: { messages: ids(66, 85).reverse().map(wire) },
    } as never)
    await ui.until(() => ui.list(2).length === 35, "server page across the hole")
    expect(texts(ui, 2).slice(0, 2)).toEqual(["m66", "m67"])

    // Below 66 everything is certified now: the next page is local.
    const sent = transport.sent.length
    ui.post({ kind: "ensure", sub: 2, range: "older" })
    await ui.until(() => ui.list(2).length === 55, "local certified page")
    await host.idle()
    expect(texts(ui, 2).at(0)).toBe("m46")
    expect(
      transport.sent
        .slice(sent)
        .filter(historyRequest((input) => input.beforeId != null)),
    ).toEqual([])
    expect(ui.window(2)).toMatchObject({ hasOlder: true })
  })

  it("trims the window's rows without touching coverage, and treats a repeated ensure as one", async () => {
    const { host, transport, ui } = await start()
    await ui.until(() => ui.list(2).length === 15, "latest certified run")

    // Two identical requests while the first is in flight: one RPC.
    ui.post({ kind: "ensure", sub: 2, range: "older" })
    ui.post({ kind: "ensure", sub: 2, range: "older" })
    const older = await transport.rpc("getChatHistory", historyRequest((input) => input.beforeId === 86n))
    await transport.reply(older, {
      oneofKind: "getChatHistory",
      getChatHistory: { messages: ids(66, 85).reverse().map(wire) },
    } as never)
    await ui.until(() => ui.list(2).length === 35, "one page")
    await host.idle()
    expect(transport.sent.filter(historyRequest((input) => input.beforeId === 86n))).toHaveLength(1)
    // An anchor already in the window loads nothing.
    const sent = transport.sent.length
    ui.post({ kind: "ensure", sub: 2, range: { around: messageId(90) } })
    await host.idle()
    expect(transport.sent.length).toBe(sent)

    // Trim to 80..100: rows leave the window, history stays certified.
    ui.post({ kind: "trimWindow", sub: 2, keep: { from: messageId(80), to: messageId(100) } } as unknown as Command)
    await ui.until(() => ui.list(2).length === 21, "trimmed")
    expect(texts(ui, 2).at(0)).toBe("m80")
    expect(ui.window(2)).toMatchObject({ hasOlder: true, atLatest: true })

    // Paging back is local now (the trimmed rows are certified and stored).
    ui.post({ kind: "ensure", sub: 2, range: "older" })
    await ui.until(() => ui.list(2).length === 41, "local page after trim")
    await host.idle()
    expect(texts(ui, 2).at(0)).toBe("m60")
    expect(transport.sent.filter(historyRequest((input) => input.beforeId != null))).toHaveLength(1)
  })

  it("invariant 5: an older page joins the window's certified run, so rows already shown below it are re-proven (sparse IDs)", async () => {
    // Messages 1..114 and two newer ones with much larger IDs. The replica
    // holds 65..114 and the two newest, with no coverage.
    const sparse = (id: number): DbModel =>
      ({ ...(row(id) as Extract<DbModel, { kind: DbObjectKind.Message }>), date: id >= 1_000 ? 5_000 + id : 1_000 + id })
    const disk = new FakeDisk()
    await disk.seed([
      ...seed().filter((object) => object.kind !== DbObjectKind.Message && object.kind !== DbObjectKind.HistoryCoverage),
      ...ids(65, 114).map(sparse),
      sparse(1_000),
      sparse(1_001),
    ].map((object) =>
      object.kind === DbObjectKind.Chat ? { ...object, lastMsgId: messageId(1_001) } : object,
    ))
    const transport = new ScriptedTransport()
    const host = new CoreHost({
      pageSize: 50,
      buildId: "2026-11-17T00:00:00Z-test",
      openStorage: () => disk.storage(),
      createTransport: () => transport,
      realtime: { sync: false },
      now: () => 1_000_000,
    })
    hosts.push(host)
    const ui = new TestContext(host)
    ui.post({ kind: "session", action: "start", session: { userId: me, token: "token" } })
    ui.subscribeTo(1, { kind: "core" })
    await ui.until(() => ui.core(1)?.phase === "ready", "ready")

    // Offline: the first frame and an older page come from local rows.
    ui.subscribeTo(2, { kind: "chatWindow", chatId: thread, anchor: "latest" })
    await ui.until(() => ui.list(2).length === 50, "local latest")
    ui.post({ kind: "ensure", sub: 2, range: "older" })
    await ui.until(() => ui.list(2).length === 52, "local older")

    // Online: the latest refresh queued while offline certifies [67, top].
    await transport.open()
    const wireSparse = (id: number) => ({ ...wire(id), date: BigInt(id >= 1_000 ? 5_000 + id : 1_000 + id) })
    const latest = await transport.rpc("getChatHistory", historyRequest((input) => input.beforeId == null && input.afterId == null))
    await transport.reply(latest, {
      oneofKind: "getChatHistory",
      getChatHistory: { messages: [1_001, 1_000, ...ids(67, 114).reverse()].map(wireSparse) },
    } as never)
    // The refresh changes nothing visible (its window intent is stale), so
    // wait for its coverage to commit before paging.
    const coverage = () =>
      (host as unknown as { account: { db: { historyCoverage(id: string): unknown[] } } }).account.db.historyCoverage(thread)
    for (let turn = 0; turn < 200 && coverage().length === 0; turn += 1) {
      await new Promise<void>((resolve) => setImmediate(resolve))
    }
    expect(coverage()).toEqual([[67n, HISTORY_TOP]])

    // Paging older must start below the certified run (67), not below the
    // uncertified rows 65 and 66, or 65..66 would stay a hole forever.
    ui.post({ kind: "ensure", sub: 2, range: "older" })
    const older = await transport.rpc("getChatHistory", historyRequest((input) => input.beforeId != null))
    if (older.body.oneofKind !== "rpcCall" || older.body.rpcCall.input.oneofKind !== "getChatHistory") {
      throw new Error("expected getChatHistory")
    }
    const before = Number(older.body.rpcCall.input.getChatHistory.beforeId)
    await transport.reply(older, {
      oneofKind: "getChatHistory",
      getChatHistory: { messages: ids(before - 50, before - 1).reverse().map(wireSparse) },
    } as never)
    await ui.until(() => ui.list(2).length >= 100, "server older page")
    await host.idle()
    const shown = texts(ui, 2)
    expect(shown.at(-1)).toBe("m1001")
    expect((ui.window(2) as { certifiedThrough?: string }).certifiedThrough).toBe("1001")
  })

  it("invariant 5: a reconnect keeps a window paged back, and a new message joins its certified range", async () => {
    const { host, transport, ui } = await start(20, () => 0)
    await ui.until(() => ui.list(2).length === 15, "latest certified run")
    const latest = await transport.rpc("getChatHistory", historyRequest((input) => input.beforeId == null && input.afterId == null))
    await transport.reply(latest, {
      oneofKind: "getChatHistory",
      getChatHistory: { messages: ids(81, 100).reverse().map(wire) },
    } as never)
    await ui.until(() => ui.list(2).length === 20, "server latest")

    // Page older twice: once across the hole from the server, once locally.
    ui.post({ kind: "ensure", sub: 2, range: "older" })
    const older = await transport.rpc("getChatHistory", historyRequest((input) => input.beforeId === 81n))
    await transport.reply(older, {
      oneofKind: "getChatHistory",
      getChatHistory: { messages: ids(61, 80).reverse().map(wire) },
    } as never)
    await ui.until(() => ui.list(2).length === 40, "first older page")
    ui.post({ kind: "ensure", sub: 2, range: "older" })
    await ui.until(() => ui.list(2).length === 60, "second older page")
    await host.idle()
    const before = texts(ui, 2)

    // Drop the connection, come back, and receive one new message.
    await transport.disconnect()
    await ui.until(() => ui.core(1)?.connection !== "connected", "offline")
    const inits = () => transport.sent.filter((message) => message.body.oneofKind === "connectionInit").length
    const initsBefore = inits()
    for (let turn = 0; turn < 500 && inits() === initsBefore; turn += 1) {
      await new Promise<void>((resolve) => setImmediate(resolve))
    }
    await transport.open()
    await ui.until(() => ui.core(1)?.connection === "connected", "online again")
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 9_000n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: { updates: [newMessageUpdate({ ...wire(101), date: 1_101n } as never)] },
            },
          },
        },
      } as never),
    )
    await ui.until(() => texts(ui, 2).at(-1) === "m101", "new message")
    await host.idle()

    expect(texts(ui, 2)).toEqual([...before, "m101"])
    expect(ui.window(2)).toMatchObject({ atLatest: true, hasNewer: false, hasOlder: true })
    expect((ui.window(2) as { certifiedThrough?: string }).certifiedThrough).toBe("101")
  })
})

