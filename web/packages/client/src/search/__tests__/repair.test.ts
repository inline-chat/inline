import {
  GetUpdatesResult_ResultType,
  Method,
  type RpcCall,
  type RpcResult,
} from "@inline-chat/protocol/core"
import { chatId } from "@inline/ids"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { createSqliteMemoryPersistenceStore } from "../../database/sqlite/openers"
import { MemorySyncStorage } from "../../realtime/sync/sync-storage"
import { SyncEngine, type SyncRpcClient } from "../../realtime/sync/sync-engine"
import { MessageSearch } from "../engine"
import { disagreements, message } from "./fixture"

type Handler = (input: RpcCall["input"]) => RpcResult["result"]

class ScriptedClient implements SyncRpcClient {
  readonly handlers = new Map<Method, Handler>()
  async callRpc(method: Method, input: RpcCall["input"]) {
    const handler = this.handlers.get(method)
    if (!handler) throw new Error(`unexpected method ${method}`)
    return handler(input)
  }
}

const emptyPage = (input: RpcCall["input"]): RpcResult["result"] => ({
  oneofKind: "getUpdates",
  getUpdates: {
    updates: [],
    seq: input.oneofKind === "getUpdates" ? input.getUpdates.startSeq : 0n,
    date: 0n,
    final: true,
    resultType: GetUpdatesResult_ResultType.EMPTY,
    skippedSequences: [],
  },
})

describe("package 3C: the index is right after a chat-bucket repair", () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it("a TOO_LONG chat bucket replaced from a snapshot leaves the index matching the rows", async () => {
    const store = createSqliteMemoryPersistenceStore()
    await store.open()
    const db = new Db({ autoHydrate: false, persistenceStore: store })
    const search = new MessageSearch({ db, store, pause: async () => {} })
    db.insert({ kind: DbObjectKind.Chat, id: chatId(10) })
    // Cached history. The repair's latest page (271 to 320) proves 290 gone and rewrites the rest.
    for (let id = 240; id <= 300; id++) db.insert(message(10, id, `before repair ${id}`))
    db.admitHistoryPage(chatId(10), [[240n, 300n]], [])
    await db.flushPersistence()

    const peer = { type: { oneofKind: "chat" as const, chat: { chatId: 10n } } }
    const client = new ScriptedClient()
    client.handlers.set(Method.GET_UPDATES_STATE, () => ({
      oneofKind: "getUpdatesState",
      getUpdatesState: { date: 2_000n, updatesFound: false },
    }))
    client.handlers.set(Method.GET_UPDATES, (input) =>
      input.oneofKind === "getUpdates" && input.getUpdates.bucket?.type.oneofKind === "chat"
        ? {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [],
              seq: 400n,
              date: 1_500n,
              final: false,
              resultType: GetUpdatesResult_ResultType.TOO_LONG,
              skippedSequences: [],
            },
          }
        : emptyPage(input),
    )
    client.handlers.set(Method.GET_CHAT, () => ({
      oneofKind: "getChat",
      getChat: {
        chat: { id: 10n, title: "Repaired", lastMsgId: 320n, peerId: peer },
        dialog: { peer, chatId: 10n, readMaxId: 320n, unreadCount: 0 },
        pinnedMessageIds: [],
        messages: [],
      } as never,
    }))
    client.handlers.set(Method.GET_CHAT_HISTORY, () => ({
      oneofKind: "getChatHistory",
      getChatHistory: {
        messages: Array.from({ length: 50 }, (_, index) => BigInt(320 - index))
          .filter((id) => id !== 290n)
          .map((id) => ({
            id,
            chatId: 10n,
            fromId: 2n,
            peerId: peer,
            out: false,
            date: 1_700_000_000n + id,
            message: id === 300n ? "edited during the gap" : `after repair ${id}`,
          })),
      } as never,
    }))
    const engine = new SyncEngine({
      db,
      storage: new MemorySyncStorage(),
      client,
      now: () => 10_000,
      retryDelaysMs: [1_000],
    })

    await engine.connectionOpened()
    await engine.processPush([
      { update: { oneofKind: "chatHasNewUpdates", chatHasNewUpdates: { chatId: 10n, peerId: peer, updateSeq: 400 } } } as never,
    ])
    await engine.idle()
    await db.flushPersistence()

    expect(await disagreements(store)).toEqual([])
    const after = await search.findInChat({ chatId: chatId(10), query: "after repair" })
    expect(after.hits.length).toBe(48)
    expect(after.hits.some((hit) => hit.messageId === "290")).toBe(false)
    // Rows the repaired page replaced are re-indexed with their new text.
    expect((await search.search({ query: "edited during" })).hits.map((hit) => hit.messageId)).toEqual(["300"])
    // Whatever the repair kept of the old cache is exactly what search finds.
    const kept = await store.readSearchIndex((raw) =>
      raw
        .exec({ sql: "SELECT message_id FROM message WHERE chat_id = 10 AND message_id < 271 ORDER BY message_id DESC", returnValue: "resultRows" })
        .map((row) => String(row[0])),
    )
    const before = await search.findInChat({ chatId: chatId(10), query: "before repair" })
    expect(before.hits.map((hit) => hit.messageId)).toEqual(kept)
    await engine.stop()
    await search.stop()
    await store.close()
  })
})
