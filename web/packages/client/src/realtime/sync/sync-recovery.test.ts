import {
  GetUpdatesResult_ResultType,
  Method,
  SyncSkippedSequence_Reason,
  type RpcCall,
  type RpcResult,
} from "@inline-chat/protocol/core"
import { chatId, messageId, spaceId, userId } from "@inline/ids"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { Db } from "../../database"
import { HISTORY_TOP } from "../../database/history-coverage"
import { spaceMemberKey } from "../../database/models"
import { DbObjectKind } from "../../database/models"
import { MemorySyncStorage } from "./sync-storage"
import {
  SyncEngine,
  type SyncBucketStall,
  type SyncRpcClient,
} from "./sync-engine"

type Handler = (
  input: RpcCall["input"],
) => RpcResult["result"] | Promise<RpcResult["result"]>

/** A scripted server end: one handler per method, every call recorded. */
class ScriptedClient implements SyncRpcClient {
  readonly calls: Array<{ method: Method; input: RpcCall["input"] }> = []
  readonly handlers = new Map<Method, Handler>()

  constructor() {
    this.handlers.set(Method.GET_UPDATES_STATE, () => ({
      oneofKind: "getUpdatesState",
      getUpdatesState: { date: 2_000n, updatesFound: false },
    }))
    this.handlers.set(Method.GET_UPDATES, (input) => ({
      oneofKind: "getUpdates",
      getUpdates: {
        updates: [],
        seq:
          input.oneofKind === "getUpdates"
            ? input.getUpdates.startSeq
            : 0n,
        date: 0n,
        final: true,
        resultType: GetUpdatesResult_ResultType.EMPTY,
        skippedSequences: [],
      },
    }))
  }

  async callRpc(method: Method, input: RpcCall["input"]) {
    this.calls.push({ method, input })
    const handler = this.handlers.get(method)
    if (!handler) throw new Error(`unexpected method ${method}`)
    return await handler(input)
  }

  count(method: Method, bucket?: "user" | "space" | "chat") {
    return this.calls.filter(
      (call) =>
        call.method === method &&
        (bucket == null ||
          (call.input.oneofKind === "getUpdates" &&
            call.input.getUpdates.bucket?.type.oneofKind === bucket)),
    ).length
  }
}

const tooLong = (seq: number): RpcResult["result"] => ({
  oneofKind: "getUpdates",
  getUpdates: {
    updates: [],
    seq: BigInt(seq),
    date: 1_500n,
    final: false,
    resultType: GetUpdatesResult_ResultType.TOO_LONG,
    skippedSequences: [],
  },
})

const createEngine = (options: { maxRetryAttempts?: number } = {}) => {
  const db = new Db({ autoHydrate: false })
  const storage = new MemorySyncStorage()
  const client = new ScriptedClient()
  const stalls: SyncBucketStall[] = []
  const engine = new SyncEngine({
    db,
    storage,
    client,
    now: () => 10_000,
    retryDelaysMs: [1_000, 2_000, 4_000],
    onBucketStalled: (stall) => stalls.push(stall),
    ...options,
  })
  return { db, storage, client, engine, stalls }
}

describe("SyncEngine bounded recovery", () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it("repairs a user bucket whose bounded replay is still TOO_LONG from an authoritative snapshot", async () => {
    const context = createEngine()
    context.client.handlers.set(Method.GET_UPDATES, () => tooLong(20_000))
    context.client.handlers.set(Method.GET_UPDATES_STATE, (input) => ({
      oneofKind: "getUpdatesState",
      getUpdatesState:
        input.oneofKind === "getUpdatesState" &&
        input.getUpdatesState.date == null
          ? { date: 3_000n, seq: 20_004 }
          : { date: 2_000n, updatesFound: false },
    }))
    context.client.handlers.set(Method.GET_CHATS, () => ({
      oneofKind: "getChats",
      getChats: {
        dialogs: [],
        chats: [{ id: 10n, title: "Repaired", date: 2_900n }],
        spaces: [],
        users: [{ id: 8n, firstName: "Dena" }],
        messages: [],
        folders: [],
      } as never,
    }))
    context.client.handlers.set(Method.GET_ME, () => ({
      oneofKind: "getMe",
      getMe: { user: { id: 7n, firstName: "Mo" } } as never,
    }))

    context.db.admitHistoryPage(chatId(10), [[1n, 100n]], [])
    expect(context.db.historyCoverage(chatId(10))).toEqual([[1n, 100n]])

    await context.engine.connectionOpened()
    await context.engine.idle()

    // invariant 5: a catalog proves no history, and the gap may have hidden
    // chat-bucket work, so the chat's coverage starts over.
    expect(context.db.historyCoverage(chatId(10))).toEqual([])

    // Two replay attempts (the second bounded), then the snapshot.
    expect(context.client.count(Method.GET_UPDATES, "user")).toBe(2)
    expect(context.client.count(Method.GET_CHATS)).toBe(1)
    expect(context.client.count(Method.GET_ME)).toBe(1)
    expect(
      await context.storage.getBucketState({ kind: "user" }),
    ).toEqual({ seq: 20_004, date: 3_000 })
    expect(
      context.db.get(context.db.ref(DbObjectKind.Chat, chatId(10)))?.title,
    ).toBe("Repaired")
    expect(
      context.db.get(context.db.ref(DbObjectKind.User, userId(7)))
        ?.firstName,
    ).toBe("Mo")
    expect(context.engine.stalledBuckets()).toEqual([])
    await context.engine.stop()
  })

  it("invariant 5: a chat repair resets coverage and certifies only its latest page", async () => {
    const context = createEngine()
    context.db.insert({ kind: DbObjectKind.Chat, id: chatId(10), lastMsgId: messageId(100) })
    context.db.admitHistoryPage(chatId(10), [[1n, 100n]], [])
    const peer = { type: { oneofKind: "chat" as const, chat: { chatId: 10n } } }
    context.client.handlers.set(Method.GET_UPDATES, (input) =>
      input.oneofKind === "getUpdates" && input.getUpdates.bucket?.type.oneofKind === "chat"
        ? tooLong(400)
        : {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [],
              seq: input.oneofKind === "getUpdates" ? input.getUpdates.startSeq : 0n,
              date: 0n,
              final: true,
              resultType: GetUpdatesResult_ResultType.EMPTY,
              skippedSequences: [],
            },
          },
    )
    context.client.handlers.set(Method.GET_CHAT, () => ({
      oneofKind: "getChat",
      getChat: {
        chat: { id: 10n, title: "Repaired", lastMsgId: 300n, peerId: peer },
        dialog: { peer, chatId: 10n, readMaxId: 250n, unreadCount: 50 },
        pinnedMessageIds: [],
        messages: [],
      } as never,
    }))
    context.client.handlers.set(Method.GET_CHAT_HISTORY, () => ({
      oneofKind: "getChatHistory",
      getChatHistory: {
        messages: Array.from({ length: 50 }, (_, index) => ({
          id: BigInt(300 - index),
          chatId: 10n,
          fromId: 2n,
          peerId: peer,
          out: false,
          date: BigInt(2_000 + 300 - index),
          message: `m${300 - index}`,
        })),
      } as never,
    }))

    await context.engine.connectionOpened()
    await context.engine.processPush([
      {
        update: {
          oneofKind: "chatHasNewUpdates",
          chatHasNewUpdates: { chatId: 10n, peerId: peer, updateSeq: 400 },
        },
      } as never,
    ])
    await context.engine.idle()

    expect(context.client.count(Method.GET_CHAT_HISTORY)).toBe(1)
    // The old [1, 100] is gone: the bucket skipped history it never saw.
    expect(context.db.historyCoverage(chatId(10))).toEqual([[251n, HISTORY_TOP]])
    await context.engine.stop()
  })

  it("repairs a space bucket that the server marks snapshot-repair-required", async () => {
    const context = createEngine()
    context.client.handlers.set(Method.GET_UPDATES, (input) => {
      if (
        input.oneofKind === "getUpdates" &&
        input.getUpdates.bucket?.type.oneofKind === "space"
      ) {
        return {
          oneofKind: "getUpdates",
          getUpdates: {
            updates: [],
            seq: 3n,
            date: 1_700n,
            final: true,
            resultType: GetUpdatesResult_ResultType.SLICE,
            skippedSequences: [1, 2, 3].map((seq) => ({
              seq: BigInt(seq),
              reason:
                seq === 2
                  ? SyncSkippedSequence_Reason.SNAPSHOT_REPAIR_REQUIRED
                  : SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET,
            })),
          },
        }
      }
      return {
        oneofKind: "getUpdates",
        getUpdates: {
          updates: [],
          seq: input.oneofKind === "getUpdates" ? input.getUpdates.startSeq : 0n,
          date: 0n,
          final: true,
          resultType: GetUpdatesResult_ResultType.EMPTY,
          skippedSequences: [],
        },
      }
    })
    context.client.handlers.set(Method.GET_SPACE, () => ({
      oneofKind: "getSpace",
      getSpace: {
        space: { id: 4n, name: "Repaired space", date: 1_600n },
        membership: {
          id: 70n,
          spaceId: 4n,
          userId: 1n,
          role: 1,
          date: 1_500n,
          canAccessPublicChats: true,
        },
        settings: { spaceId: 4n, gridEnabled: true },
      } as never,
    }))

    await context.engine.connectionOpened()
    await context.engine.processPush([
      {
        update: {
          oneofKind: "spaceHasNewUpdates",
          spaceHasNewUpdates: { spaceId: 4n, updateSeq: 3 },
        },
      } as never,
    ])
    await context.engine.idle()

    expect(context.client.count(Method.GET_SPACE)).toBe(1)
    expect(
      await context.storage.getBucketState({
        kind: "space",
        spaceId: spaceId(4),
      }),
    ).toEqual({ seq: 3, date: 1_700 })
    expect(
      context.db.get(context.db.ref(DbObjectKind.Space, spaceId(4))),
    ).toMatchObject({
      name: "Repaired space",
      // The account's membership and the settings come with the snapshot;
      // the roster does not.
      gridEnabled: true,
      memberRosterComplete: false,
    })
    expect(
      context.db.get(context.db.ref(DbObjectKind.SpaceMember, spaceMemberKey(spaceId(4), userId(1)))),
    ).toMatchObject({ memberId: "70", role: "admin", canAccessPublicChats: true })
    await context.engine.stop()
  })

  it("stops a bucket that cannot be repaired in a visible state instead of retrying", async () => {
    const context = createEngine()
    // A server without the user sequence in getUpdatesState cannot give a
    // repair checkpoint.
    context.client.handlers.set(Method.GET_UPDATES, () => tooLong(20_000))

    await context.engine.connectionOpened()
    await context.engine.idle()
    await vi.advanceTimersByTimeAsync(10 * 60_000)
    await context.engine.idle()

    expect(context.client.count(Method.GET_UPDATES, "user")).toBe(2)
    expect(context.stalls).toHaveLength(1)
    expect(context.engine.stalledBuckets()).toMatchObject([
      { bucketId: "user", reason: "repair-unavailable", attempts: 1 },
    ])
    await context.engine.stop()
  })

  it("does not spin when the server declares a bucket complete below its own hint", async () => {
    const context = createEngine({ maxRetryAttempts: 3 })
    await context.engine.connectionOpened()
    await context.engine.idle()
    const before = context.client.count(Method.GET_UPDATES, "user")

    // The default server answers every page as final at the start sequence.
    await context.engine.processPush([
      {
        update: {
          oneofKind: "userHasNewUpdates",
          userHasNewUpdates: { updateSeq: 9 },
        },
      } as never,
    ])
    await context.engine.idle()
    expect(context.client.count(Method.GET_UPDATES, "user") - before).toBe(1)

    await vi.advanceTimersByTimeAsync(60_000)
    await context.engine.idle()
    expect(context.client.count(Method.GET_UPDATES, "user") - before).toBe(3)
    expect(context.engine.stalledBuckets()).toMatchObject([
      { bucketId: "user", reason: "retry-limit", attempts: 3 },
    ])
    await context.engine.stop()
  })

  it("caps a failing bucket's retries and stalls it until the next connection", async () => {
    const context = createEngine({ maxRetryAttempts: 4 })
    context.client.handlers.set(Method.GET_UPDATES, () => {
      throw new Error("RPC timed out")
    })

    await context.engine.connectionOpened()
    await context.engine.idle()
    expect(context.client.count(Method.GET_UPDATES, "user")).toBe(1)

    // Backoff 1s, 2s, 4s: three retries, then the cap.
    await vi.advanceTimersByTimeAsync(1_000)
    await context.engine.idle()
    expect(context.client.count(Method.GET_UPDATES, "user")).toBe(2)
    await vi.advanceTimersByTimeAsync(2_000)
    await context.engine.idle()
    await vi.advanceTimersByTimeAsync(4_000)
    await context.engine.idle()
    expect(context.client.count(Method.GET_UPDATES, "user")).toBe(4)
    expect(context.engine.stalledBuckets()).toMatchObject([
      { bucketId: "user", reason: "retry-limit", attempts: 4 },
    ])

    // Nothing runs any more on this connection, hints included.
    await vi.advanceTimersByTimeAsync(60 * 60_000)
    await context.engine.processPush([
      {
        update: {
          oneofKind: "userHasNewUpdates",
          userHasNewUpdates: { updateSeq: 9 },
        },
      } as never,
    ])
    await context.engine.idle()
    expect(context.client.count(Method.GET_UPDATES, "user")).toBe(4)
    expect(context.stalls).toHaveLength(1)

    // A new connection gets a fresh budget, and a recovered server clears it.
    context.client.handlers.delete(Method.GET_UPDATES)
    context.client.handlers.set(Method.GET_UPDATES, (input) => ({
      oneofKind: "getUpdates",
      getUpdates: {
        updates: [],
        seq: input.oneofKind === "getUpdates" ? input.getUpdates.startSeq : 0n,
        date: 0n,
        final: true,
        resultType: GetUpdatesResult_ResultType.EMPTY,
        skippedSequences: [],
      },
    }))
    context.engine.connectionInterrupted()
    await context.engine.connectionOpened()
    await context.engine.idle()
    expect(context.client.count(Method.GET_UPDATES, "user")).toBe(5)
    expect(context.engine.stalledBuckets()).toEqual([])
    await context.engine.stop()
  })
})
