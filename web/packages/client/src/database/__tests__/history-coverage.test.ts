import {
  Update,
  type Message as ProtocolMessage,
  type RpcResult,
} from "@inline-chat/protocol/core"
import { chatId, dialogId, messageId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { createFaultableSqliteStore } from "../../testing/faultable-sqlite-store"
import { applyUpdates } from "../../realtime/updates/apply-updates"
import {
  getChatHistory,
  GetChatHistoryMode,
  type GetChatHistoryContext,
} from "../../realtime/transactions/get-chat-history"
import { readMessages } from "../../realtime/transactions/read-messages"
import {
  certifiedReadMaxId,
  HISTORY_TOP,
  isCertified,
  provenRanges,
  windowEdges,
} from "../history-coverage"
import { Db } from "../index"
import { DbObjectKind, messageKey, type Message } from "../models"
import type { InlinePersistenceStore } from "../persistence"
import { Method } from "@inline-chat/protocol/core"
import { DemoServerModel } from "../../testing/demo-server-model"
import type { DemoAccount } from "../../testing/demo-account"
import { chatInputPeer } from "../../testing/server-model"

const chat = chatId(10)
const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: 10n } } }

const row = (id: number): Message => ({
  kind: DbObjectKind.Message,
  id: messageKey(chat, messageId(id)),
  messageId: messageId(id),
  chatId: chat,
  fromId: userId(2),
  message: `m${id}`,
  date: 1_000 + id,
})

const wire = (id: number): ProtocolMessage => ({
  id: BigInt(id),
  chatId: 10n,
  fromId: 2n,
  peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
  out: false,
  message: `m${id}`,
  date: BigInt(1_000 + id),
})

const page = (ids: number[]): RpcResult["result"] => ({
  oneofKind: "getChatHistory",
  getChatHistory: { messages: ids.map(wire) } as never,
})

const range = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, i) => from + i)

const setup = async (store: InlinePersistenceStore) => {
  const db = new Db({ autoHydrate: false, persistenceStore: store })
  await db.openPersistence()
  await db.commit(() => {
    db.insert({ kind: DbObjectKind.Chat, id: chat, lastMsgId: messageId(300) })
    db.insert({
      kind: DbObjectKind.Dialog,
      id: dialogId(-10),
      chatId: chat,
      peerThreadId: chat,
      readMaxId: messageId(90),
    })
  })
  return db
}

/** Run a history page the way the realtime client does: apply inside one commit. */
const admitPage = async (db: Db, context: GetChatHistoryContext, result: RpcResult["result"]) => {
  const transaction = getChatHistory({ peerId, ...context })
  transaction.beforeExecute(db)
  await db.commit(() => transaction.apply(result, db))
}

const reload = async (store: InlinePersistenceStore) => {
  const db = new Db({ autoHydrate: false, persistenceStore: store })
  await db.hydrate()
  return db
}

describe("invariant 5: certified history is stored apart from cached rows", () => {
  it("invariant 5: a stored row does not close a hole", async () => {
    const { store } = createFaultableSqliteStore()
    const db = await setup(store)
    // Two latest-era pages certify [1, 100] and [201, 300].
    await admitPage(db, { mode: GetChatHistoryMode.HISTORY_MODE_AROUND, anchorId: messageId(50), beforeLimit: 49, afterLimit: 50, limit: 100 }, page(range(1, 100)))
    await admitPage(db, { mode: GetChatHistoryMode.HISTORY_MODE_OLDER, beforeId: messageId(301), limit: 100 }, page(range(201, 300)))
    // A row cached in the hole (from sync or a reply reference).
    await db.commit(() => db.insert(row(150)))

    const ranges = db.historyCoverage(chat)
    expect(ranges).toEqual([[1n, 100n], [201n, 300n]])
    expect(isCertified(ranges, 101n, 200n)).toBe(false)
    expect(windowEdges({ ranges, oldest: 201n, newest: 300n, lastMsgId: 300n })).toMatchObject({
      hasOlder: true,
      atLatest: false,
    })
    // The record is durable and comes back as it was.
    expect((await reload(store)).historyCoverage(chat)).toEqual(ranges)
  })

  it("invariant 5: an empty page certifies its range and removes rows the server no longer has", async () => {
    const { store } = createFaultableSqliteStore()
    const db = await setup(store)
    await db.commit(() => db.insert(row(30)))

    await admitPage(db, { mode: GetChatHistoryMode.HISTORY_MODE_OLDER, beforeId: messageId(50), limit: 20 }, page([]))

    expect(db.historyCoverage(chat)).toEqual([[1n, 49n]])
    expect(db.get(db.ref(DbObjectKind.Message, messageKey(chat, messageId(30))))).toBeUndefined()
    const reloaded = await reload(store)
    expect(await reloaded.readStoredObjects(DbObjectKind.Message, [messageKey(chat, messageId(30))])).toEqual([])
  })

  it("invariant 5: a failed page rolls back its rows and its coverage together", async () => {
    const faults = createFaultableSqliteStore()
    const db = await setup(faults.store)

    faults.failNextWrite(new Error("disk full"))
    await expect(
      admitPage(db, { mode: GetChatHistoryMode.HISTORY_MODE_LATEST, limit: 20 }, page(range(281, 300))),
    ).rejects.toThrow()

    expect(db.historyCoverage(chat)).toEqual([])
    expect(db.get(db.ref(DbObjectKind.Message, messageKey(chat, messageId(300))))).toBeUndefined()
    const reloaded = await reload(faults.store)
    expect(reloaded.historyCoverage(chat)).toEqual([])
    expect(await reloaded.readStoredObjects(DbObjectKind.Message, [messageKey(chat, messageId(300))])).toEqual([])
  })

  it("invariant 5: read state stops at the first hole", async () => {
    const { store } = createFaultableSqliteStore()
    const db = await setup(store)
    await admitPage(db, { mode: GetChatHistoryMode.HISTORY_MODE_AROUND, anchorId: messageId(50), beforeLimit: 49, afterLimit: 50, limit: 100 }, page(range(1, 100)))
    await admitPage(db, { mode: GetChatHistoryMode.HISTORY_MODE_LATEST, limit: 100 }, page(range(201, 300)))

    const read = readMessages({ peerId, maxId: messageId(250) })
    read.beforeExecute(db)
    expect(read.context.maxId).toBe(messageId(100))
    await db.commit(() => read.optimistic(db))
    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-10)))?.readMaxId).toBe(messageId(100))

    // At the hole already: the frontier stays where it is.
    const again = readMessages({ peerId, maxId: messageId(250) })
    again.beforeExecute(db)
    expect(again.context.maxId).toBe(messageId(100))

    expect(certifiedReadMaxId([[1n, 100n], [201n, HISTORY_TOP]], 210n, 250n)).toBe(250n)
  })

  it("invariant 5: deleting a message keeps coverage; clearing history resets it", async () => {
    const { store } = createFaultableSqliteStore()
    const db = await setup(store)
    await admitPage(db, { mode: GetChatHistoryMode.HISTORY_MODE_LATEST, limit: 20 }, page(range(281, 300)))
    expect(db.historyCoverage(chat)).toEqual([[281n, HISTORY_TOP]])

    await db.commit(() => {
      applyUpdates(db, [
        Update.create({
          update: {
            oneofKind: "deleteMessages",
            deleteMessages: { messageIds: [290n], peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } } },
          },
        }),
      ], "realtime")
    })
    expect(db.get(db.ref(DbObjectKind.Message, messageKey(chat, messageId(290))))).toBeUndefined()
    expect(db.historyCoverage(chat)).toEqual([[281n, HISTORY_TOP]])

    await db.commit(() => db.clearMessagesForChat(chat))
    expect(db.historyCoverage(chat)).toEqual([])
    expect((await reload(store)).historyCoverage(chat)).toEqual([])
  })

  it("invariant 5: proves only what a page can prove", () => {
    // A full latest page proves from its oldest row up; a short one from 1.
    expect(provenRanges({ mode: "latest", limit: 3 }, [8n, 9n, 10n])).toEqual([[8n, HISTORY_TOP]])
    expect(provenRanges({ mode: "latest", limit: 3 }, [9n, 10n])).toEqual([[1n, HISTORY_TOP]])
    // An older page proves below its boundary only.
    expect(provenRanges({ mode: "older", beforeId: 50n, limit: 2 }, [48n, 49n])).toEqual([[48n, 49n]])
    // An excluded anchor stays a gap.
    expect(
      provenRanges({ mode: "around", anchorId: 10n, beforeLimit: 2, afterLimit: 2, includeAnchor: false }, [8n, 9n, 11n, 12n]),
    ).toEqual([[8n, 9n], [11n, 12n]])
    // A page that does not match its request proves nothing.
    expect(provenRanges({ mode: "older", beforeId: 50n, limit: 2 }, [49n, 50n])).toBeUndefined()
    expect(provenRanges({ mode: "latest", limit: 500 }, [])).toBeUndefined()
  })

  describe("invariant 5: pages through the real history transaction join into one range", () => {
    /** Messages 1..114 and two newer ones with much larger IDs (1000, 1001). */
    const server = () => {
      const model = new DemoServerModel(
        { selfUserId: 7n, users: [], spaces: [], anchor: 0 } as unknown as DemoAccount,
        { now: () => 1_000 },
      )
      model.addUser(2n, "Ada")
      const modelChat = model.addChat({ id: 10n, participants: [2n] })
      for (let id = 1; id <= 114; id += 1) model.postMessage({ chatId: 10n, fromId: 2n, text: `m${id}` })
      modelChat.nextMessageId = 1_000n
      model.postMessage({ chatId: 10n, fromId: 2n, text: "m1000" })
      model.postMessage({ chatId: 10n, fromId: 2n, text: "m1001" })
      return model
    }
    const serve = (model: DemoServerModel, context: GetChatHistoryContext) => {
      const transaction = getChatHistory({ peerId: chatInputPeer(10n), ...context })
      const outcome = model.handleRpc(1, Method.GET_CHAT_HISTORY, transaction.input(transaction.context))
      if (!("result" in outcome)) throw new Error("expected history")
      return outcome.result
    }
    const run = async (db: Db, model: DemoServerModel, context: GetChatHistoryContext) => {
      const result = serve(model, context)
      await admitPage(db, context, result)
      return result?.oneofKind === "getChatHistory" ? result.getChatHistory.messages.map((m) => m.id) : []
    }

    it("latest, then older twice: one range from the oldest page to the top", async () => {
      const { store } = createFaultableSqliteStore()
      const db = await setup(store)
      const model = server()
      const latest = await run(db, model, { mode: GetChatHistoryMode.HISTORY_MODE_LATEST, limit: 50 })
      expect(latest.at(-1)).toBe(67n)
      const first = await run(db, model, { mode: GetChatHistoryMode.HISTORY_MODE_OLDER, beforeId: messageId(67), limit: 50 })
      expect(first.at(-1)).toBe(17n)
      expect(db.historyCoverage(chat)).toEqual([[17n, HISTORY_TOP]])
      await run(db, model, { mode: GetChatHistoryMode.HISTORY_MODE_OLDER, beforeId: messageId(17), limit: 50 })
      expect(db.historyCoverage(chat)).toEqual([[1n, HISTORY_TOP]])
    })

    it("around, then newer up to the top, then older: one range", async () => {
      const { store } = createFaultableSqliteStore()
      const db = await setup(store)
      const model = server()
      await run(db, model, {
        mode: GetChatHistoryMode.HISTORY_MODE_AROUND,
        anchorId: messageId(50),
        beforeLimit: 10,
        afterLimit: 10,
        includeAnchor: true,
        limit: 21,
      })
      expect(db.historyCoverage(chat)).toEqual([[40n, 60n]])
      await run(db, model, { mode: GetChatHistoryMode.HISTORY_MODE_NEWER, afterId: messageId(60), limit: 50 })
      expect(db.historyCoverage(chat)).toEqual([[40n, 110n]])
      // The next newer page is short: it reaches the top across the ID jump.
      await run(db, model, { mode: GetChatHistoryMode.HISTORY_MODE_NEWER, afterId: messageId(110), limit: 50 })
      expect(db.historyCoverage(chat)).toEqual([[40n, HISTORY_TOP]])
      await run(db, model, { mode: GetChatHistoryMode.HISTORY_MODE_OLDER, beforeId: messageId(40), limit: 50 })
      expect(db.historyCoverage(chat)).toEqual([[1n, HISTORY_TOP]])
    })
  })

  it("invariant 5: a latest refresh keeps window rows its certified range proves contiguous, and drops rows across a hole", async () => {
    const { store } = createFaultableSqliteStore()
    const db = await setup(store)
    db.activateResidentMessageWindow(chat)
    const runPage = async (context: GetChatHistoryContext, result: RpcResult["result"]) => {
      const transaction = getChatHistory({ peerId, ...context })
      transaction.beforeExecute(db)
      await db.commit(() => transaction.apply(result, db))
      transaction.afterCommit(result, db)
    }
    const members = () =>
      db.fullChatWindows
        .keys(chat)
        .map((key) => Number(key.split(":")[1]))
        .sort((a, b) => a - b)

    await runPage({ mode: GetChatHistoryMode.HISTORY_MODE_LATEST, limit: 20 }, page(range(281, 300)))
    await runPage({ mode: GetChatHistoryMode.HISTORY_MODE_OLDER, beforeId: messageId(281), limit: 20 }, page(range(261, 280)))
    expect(members()).toEqual(range(261, 300))

    // A reconnect's latest refresh: the reader keeps the rows they paged to.
    await runPage({ mode: GetChatHistoryMode.HISTORY_MODE_LATEST, limit: 20 }, page(range(281, 300)))
    expect(members()).toEqual(range(261, 300))
    expect(db.historyCoverage(chat)).toEqual([[261n, HISTORY_TOP]])

    // After a repair reset coverage, the old rows are no longer proven
    // contiguous with the new latest page and leave the window.
    await db.commit(() => db.resetHistoryCoverage(chat))
    await runPage({ mode: GetChatHistoryMode.HISTORY_MODE_LATEST, limit: 20 }, page(range(281, 300)))
    expect(members()).toEqual(range(281, 300))
  })
})

