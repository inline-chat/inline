import {
  GetUpdatesResult_ResultType,
  Method,
  SyncSkippedSequence_Reason,
  Update,
  type RpcCall,
  type RpcResult,
} from "@inline-chat/protocol/core"
import { chatId, messageId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { Db } from "../../database"
import {
  DbObjectKind,
  messageKey,
  type Message,
} from "../../database/models"
import type { CollectionStorage } from "../../database/storage"
import { DbQueryPlanType } from "../../database/types"
import { MemorySyncStorage } from "./sync-storage"
import { SyncEngine, type SyncRpcClient } from "./sync-engine"
import type { SyncBucketKey } from "./sync-types"

const chatPeer = {
  type: {
    oneofKind: "chat" as const,
    chat: { chatId: 10n },
  },
}

const chatKey: SyncBucketKey = {
  kind: "chat",
  peer: chatPeer,
}

const messageUpdate = (seq: number, messageId: number) =>
  Update.create({
    seq,
    date: BigInt(1_000 + seq),
    update: {
      oneofKind: "newMessage",
      newMessage: {
        message: {
          id: BigInt(messageId),
          chatId: 10n,
          peerId: chatPeer,
          fromId: 7n,
          out: false,
          date: BigInt(1_000 + seq),
          message: `message ${messageId}`,
        },
      },
    },
  })

const hint = (seq: number) =>
  Update.create({
    update: {
      oneofKind: "chatHasNewUpdates",
      chatHasNewUpdates: {
        chatId: 10n,
        peerId: chatPeer,
        updateSeq: seq,
      },
    },
  })

class FakeSyncClient implements SyncRpcClient {
  readonly calls: Array<{ method: Method; input: RpcCall["input"] }> = []
  chatUpdates: (
    input: Extract<RpcCall["input"], { oneofKind: "getUpdates" }>,
  ) => RpcResult["result"] = () => ({
    oneofKind: "getUpdates",
    getUpdates: {
      updates: [],
      seq: 0n,
      date: 0n,
      final: true,
      resultType: GetUpdatesResult_ResultType.EMPTY,
      skippedSequences: [],
    },
  })
  userUpdates: (
    input: Extract<RpcCall["input"], { oneofKind: "getUpdates" }>,
  ) => RpcResult["result"] = (input) => ({
    oneofKind: "getUpdates",
    getUpdates: {
      updates: [],
      seq: input.getUpdates.startSeq,
      date: 0n,
      final: true,
      resultType: GetUpdatesResult_ResultType.EMPTY,
      skippedSequences: [],
    },
  })
  chatSnapshot?: RpcResult["result"]
  chatHistory?: RpcResult["result"]

  async callRpc(method: Method, input: RpcCall["input"]) {
    this.calls.push({ method, input })

    if (method === Method.GET_UPDATES_STATE) {
      return {
        oneofKind: "getUpdatesState" as const,
        getUpdatesState: {
          date: 2_000n,
          updatesFound: false,
        },
      }
    }
    if (method === Method.GET_CHAT) {
      if (!this.chatSnapshot) throw new Error("missing chat snapshot")
      return this.chatSnapshot
    }
    if (method === Method.GET_CHAT_HISTORY) {
      if (!this.chatHistory) throw new Error("missing chat history")
      return this.chatHistory
    }
    if (method !== Method.GET_UPDATES || input.oneofKind !== "getUpdates") {
      throw new Error(`unexpected method ${method}`)
    }

    if (input.getUpdates.bucket?.type.oneofKind === "user") {
      return this.userUpdates(input)
    }
    return this.chatUpdates(input)
  }
}

const createEngine = (
  db = new Db({ autoHydrate: false }),
  storage = new MemorySyncStorage(),
  client = new FakeSyncClient(),
) => ({
  db,
  storage,
  client,
  engine: new SyncEngine({
    db,
    storage,
    client,
    now: () => 10_000,
    retryDelaysMs: [60_000],
  }),
})

describe("SyncEngine", () => {
  it("leaves the cold-start budget after TOO_LONG and completes the bounded slice", async () => {
    const context = createEngine()
    let response = 0
    context.client.userUpdates = () => {
      response += 1
      if (response === 1) {
        return {
          oneofKind: "getUpdates",
          getUpdates: {
            updates: [],
            seq: 500n,
            date: 1_500n,
            final: false,
            resultType: GetUpdatesResult_ResultType.TOO_LONG,
            skippedSequences: [],
          },
        }
      }
      return {
        oneofKind: "getUpdates",
        getUpdates: {
          updates: [],
          seq: 500n,
          date: 1_500n,
          final: true,
          resultType: GetUpdatesResult_ResultType.EMPTY,
          skippedSequences: Array.from({ length: 500 }, (_, index) => ({
            seq: BigInt(index + 1),
            reason:
              SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET,
          })),
        },
      }
    }

    await context.engine.connectionOpened()
    await context.engine.idle()

    const requests = context.client.calls.flatMap(({ method, input }) =>
      method === Method.GET_UPDATES &&
        input.oneofKind === "getUpdates" &&
        input.getUpdates.bucket?.type.oneofKind === "user"
        ? [input.getUpdates]
        : [],
    )
    expect(requests).toHaveLength(2)
    expect(requests.map((request) => request.totalLimit)).toEqual([
      50,
      1_000,
    ])
    expect(requests.map((request) => request.seqEnd)).toEqual([
      0n,
      500n,
    ])
    expect(
      await context.storage.getBucketState({ kind: "user" }),
    ).toEqual({ seq: 500, date: 1_500 })
    await context.engine.stop()
  })

  it("backs off instead of busy-looping when a server repeats a TOO_LONG boundary", async () => {
    const context = createEngine()
    context.client.userUpdates = () => ({
      oneofKind: "getUpdates",
      getUpdates: {
        updates: [],
        seq: 500n,
        date: 1_500n,
        final: false,
        resultType: GetUpdatesResult_ResultType.TOO_LONG,
        skippedSequences: [],
      },
    })

    await context.engine.connectionOpened()
    await context.engine.idle()

    const userFetchCount = () =>
      context.client.calls.filter(
        ({ method, input }) =>
          method === Method.GET_UPDATES &&
          input.oneofKind === "getUpdates" &&
          input.getUpdates.bucket?.type.oneofKind === "user",
      ).length
    expect(userFetchCount()).toBe(2)
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(userFetchCount()).toBe(2)
    await context.engine.stop()
  })

  it("fills a realtime sequence gap before applying the newest message", async () => {
    const context = createEngine()
    const first = messageUpdate(1, 101)
    const second = messageUpdate(2, 102)
    context.client.chatUpdates = () => ({
      oneofKind: "getUpdates",
      getUpdates: {
        updates: [first, second],
        seq: 2n,
        date: 1_002n,
        final: true,
        resultType: GetUpdatesResult_ResultType.SLICE,
        skippedSequences: [],
      },
    })

    await context.engine.connectionOpened()
    await context.engine.processPush([second])
    await context.engine.idle()

    expect(
      context.db.get(
        context.db.ref(
          DbObjectKind.Message,
          messageKey(chatId(10), messageId(101)),
        ),
      )?.message,
    ).toBe("message 101")
    expect(
      context.db.get(
        context.db.ref(
          DbObjectKind.Message,
          messageKey(chatId(10), messageId(102)),
        ),
      )?.message,
    ).toBe("message 102")
    expect(await context.storage.getBucketState(chatKey)).toMatchObject({
      seq: 2,
    })
    await context.engine.stop()
  })

  it("applies the next contiguous realtime update without a catch-up RPC", async () => {
    const context = createEngine()
    await context.storage.setBucketState(chatKey, {
      seq: 1,
      date: 1_001,
    })

    await context.engine.connectionOpened()
    await context.engine.processPush([messageUpdate(2, 102)])
    await context.engine.idle()

    const chatFetches = context.client.calls.filter(
      ({ method, input }) =>
        method === Method.GET_UPDATES &&
        input.oneofKind === "getUpdates" &&
        input.getUpdates.bucket?.type.oneofKind === "chat",
    )
    expect(chatFetches).toHaveLength(0)
    expect(await context.storage.getBucketState(chatKey)).toMatchObject({
      seq: 2,
    })
    await context.engine.stop()
  })

  it("reconciles both candidates without guessing an ambiguous bucket cursor", async () => {
    const context = createEngine()
    await context.engine.connectionOpened()
    await context.engine.idle()
    context.client.calls.length = 0

    await context.engine.processPush([
      Update.create({
        seq: 1,
        date: 1_001n,
        update: {
          oneofKind: "participantDelete",
          participantDelete: {
            chatId: 10n,
            userId: 7n,
          },
        },
      }),
    ])
    await context.engine.idle()

    const fetchedBucketKinds = context.client.calls
      .filter(
        ({ method, input }) =>
          method === Method.GET_UPDATES &&
          input.oneofKind === "getUpdates",
      )
      .map(
        ({ input }) =>
          input.oneofKind === "getUpdates"
            ? input.getUpdates.bucket?.type.oneofKind
            : undefined,
      )
    expect(fetchedBucketKinds).toContain("user")
    expect(fetchedBucketKinds).toContain("chat")
    expect(await context.storage.getBucketState(chatKey)).toEqual({
      seq: 0,
      date: 0,
    })
    expect(
      context.db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.DeferredUpdate,
      ),
    ).toHaveLength(1)
    await context.engine.stop()
  })

  it("does not advance a cursor for a page with an unaccounted gap", async () => {
    const context = createEngine()
    context.client.chatUpdates = () => ({
      oneofKind: "getUpdates",
      getUpdates: {
        updates: [messageUpdate(2, 102)],
        seq: 2n,
        date: 1_002n,
        final: true,
        resultType: GetUpdatesResult_ResultType.SLICE,
        skippedSequences: [],
      },
    })

    await context.engine.connectionOpened()
    await context.engine.processPush([hint(2)])
    await context.engine.idle()

    expect(await context.storage.getBucketState(chatKey)).toEqual({
      seq: 0,
      date: 0,
    })
    await context.engine.stop()
  })

  it("does not advance a cursor when object persistence fails", async () => {
    const messageStorage: CollectionStorage<Message> = {
      init: async () => {},
      get: async () => undefined,
      getAll: async () => [],
      put: async () => {
        throw new Error("disk full")
      },
      delete: async () => {},
      deleteAllByChatId: async () => {},
    }
    const db = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.Message]: messageStorage,
      },
    })
    const context = createEngine(db)
    context.client.chatUpdates = () => ({
      oneofKind: "getUpdates",
      getUpdates: {
        updates: [messageUpdate(1, 101)],
        seq: 1n,
        date: 1_001n,
        final: true,
        resultType: GetUpdatesResult_ResultType.SLICE,
        skippedSequences: [],
      },
    })

    await context.engine.connectionOpened()
    await context.engine.processPush([hint(1)])
    await context.engine.idle()

    expect(await context.storage.getBucketState(chatKey)).toEqual({
      seq: 0,
      date: 0,
    })
    await context.engine.stop()
  })

  it("rolls back a page and its cursor when one update is unclassifiable", async () => {
    const context = createEngine()
    context.db.insert({
      kind: DbObjectKind.Chat,
      id: chatId(10),
      title: "Before",
    })
    context.client.chatUpdates = () => ({
      oneofKind: "getUpdates",
      getUpdates: {
        updates: [
          Update.create({
            seq: 1,
            date: 1_001n,
            update: {
              oneofKind: "chatInfo",
              chatInfo: {
                chatId: 10n,
                title: "Must roll back",
              },
            },
          }),
          Update.create({
            seq: 2,
            date: 1_002n,
          }),
        ],
        seq: 2n,
        date: 1_002n,
        final: true,
        resultType: GetUpdatesResult_ResultType.SLICE,
        skippedSequences: [],
      },
    })

    await context.engine.connectionOpened()
    await context.engine.processPush([hint(2)])
    await context.engine.idle()

    expect(
      context.db.get(
        context.db.ref(DbObjectKind.Chat, chatId(10)),
      )?.title,
    ).toBe("Before")
    expect(await context.storage.getBucketState(chatKey)).toEqual({
      seq: 0,
      date: 0,
    })
    await context.engine.stop()
  })

  it("repairs a cold chat with a bounded current-state snapshot", async () => {
    const context = createEngine()
    context.client.chatUpdates = () => ({
      oneofKind: "getUpdates",
      getUpdates: {
        updates: [],
        seq: 500n,
        date: 2_500n,
        final: true,
        resultType: GetUpdatesResult_ResultType.TOO_LONG,
        skippedSequences: [],
      },
    })
    context.client.chatSnapshot = {
      oneofKind: "getChat",
      getChat: {
        chat: {
          id: 10n,
          title: "Repaired thread",
          peerId: chatPeer,
        },
        dialog: {
          chatId: 10n,
          peer: chatPeer,
          open: true,
        },
        pinnedMessageIds: [],
      },
    }
    context.client.chatHistory = {
      oneofKind: "getChatHistory",
      getChatHistory: {
        messages: [
          {
            id: 500n,
            chatId: 10n,
            peerId: chatPeer,
            fromId: 7n,
            out: false,
            date: 2_500n,
            message: "Latest",
          },
        ],
      },
    }

    await context.engine.connectionOpened()
    await context.engine.processPush([hint(500)])
    await context.engine.idle()

    expect(
      context.db.get(context.db.ref(DbObjectKind.Chat, chatId(10)))?.title,
    ).toBe(
      "Repaired thread",
    )
    expect(
      context.db.get(
        context.db.ref(
          DbObjectKind.Message,
          messageKey(chatId(10), messageId(500)),
        ),
      )?.message,
    ).toBe("Latest")
    expect(await context.storage.getBucketState(chatKey)).toEqual({
      seq: 500,
      date: 2_500,
    })
    await context.engine.stop()
  })
})
