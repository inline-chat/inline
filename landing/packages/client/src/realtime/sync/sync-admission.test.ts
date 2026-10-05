import {
  GetUpdatesResult_ResultType,
  Method,
  SyncSkippedSequence_Reason,
  Update,
  UpdateSidecars,
  type GetUpdatesResult,
  type RpcCall,
  type RpcResult,
} from "@inline-chat/protocol/core"
import { chatId, messageId } from "@inline/ids"
import { IDBFactory, IDBKeyRange } from "fake-indexeddb"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { Db } from "../../database"
import { DbObjectKind, messageKey } from "../../database/models"
import { DbQueryPlanType } from "../../database/types"
import { ReadMessagesTransaction } from "../transactions/read-messages"
import { getDialogId } from "../transactions/mappers"
import { applyUpdateSidecars } from "../updates/apply-updates"
import { DbSyncStorage } from "./db-sync-storage"
import { SyncEngine, type SyncRpcClient } from "./sync-engine"
import type { SyncBucketKey } from "./sync-types"

const peer = {
  type: { oneofKind: "chat" as const, chat: { chatId: 10n } },
}
const exactChatId = chatId(10)
const exactDialogId = getDialogId({ peerThreadId: exactChatId })
const chatKey: SyncBucketKey = { kind: "chat", peer }
type UpdatesInput = Extract<RpcCall["input"], { oneofKind: "getUpdates" }>
type RpcHandler = (
  input: RpcCall["input"],
) => RpcResult["result"] | Promise<RpcResult["result"]>

const deferred = <T>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((settle) => {
    resolve = settle
  })
  return { promise, resolve }
}

const page = (
  updates: Update[] = [],
  overrides: Partial<GetUpdatesResult> = {},
): RpcResult["result"] => ({
  oneofKind: "getUpdates",
  getUpdates: {
    updates,
    seq: BigInt(updates.at(-1)?.seq ?? 0),
    date: 1_001n,
    final: true,
    resultType: GetUpdatesResult_ResultType.SLICE,
    skippedSequences: [],
    ...overrides,
  },
})

const sidecars = (title = "Old thread", readMaxId = 5n, unreadCount = 15) =>
  UpdateSidecars.create({
    chats: [{ id: 10n, peerId: peer, title, lastMsgId: 20n }],
    dialogs: [
      {
        chatId: 10n,
        peer,
        open: true,
        readMaxId,
        unreadCount,
        unreadMark: unreadCount > 0,
      },
    ],
  })

const newMessage = (seq = 1, id = 101) =>
  Update.create({
    seq,
    date: 1_001n,
    update: {
      oneofKind: "newMessage",
      newMessage: {
        message: {
          id: BigInt(id),
          chatId: 10n,
          peerId: peer,
          fromId: 7n,
          out: false,
          date: 1_001n,
          message: `Message ${id}`,
        },
      },
    },
  })

const readUpdate = (seq: number, readMaxId = 20n, unreadCount = 0) =>
  Update.create({
    seq,
    date: 1_020n,
    update: {
      oneofKind: "updateReadMaxId",
      updateReadMaxId: { peerId: peer, readMaxId, unreadCount },
    },
  })

const removed = (seq = 1) =>
  Update.create({
    seq,
    date: 1_030n,
    update: {
      oneofKind: "userRemovedFromChat",
      userRemovedFromChat: { chatId: 10n },
    },
  })

const added = (seq = 2) =>
  Update.create({
    seq,
    date: 1_031n,
    update: { oneofKind: "userAddedToChat", userAddedToChat: { chatId: 10n } },
  })

const chatHint = (updateSeq = 1) =>
  Update.create({
    update: {
      oneofKind: "chatHasNewUpdates",
      chatHasNewUpdates: {
        chatId: 10n,
        peerId: peer,
        updateSeq,
      },
    },
  })

class FakeSyncClient implements SyncRpcClient {
  readonly calls: Array<{ method: Method; input: RpcCall["input"] }> = []
  updatesState: RpcHandler = () => ({
    oneofKind: "getUpdatesState",
    getUpdatesState: {
      date: 1_000n,
      updatesFound: false,
    },
  })
  userUpdates: (
    input: UpdatesInput,
  ) => RpcResult["result"] | Promise<RpcResult["result"]> = (input) =>
    page([], {
      seq: input.getUpdates.startSeq,
      resultType: GetUpdatesResult_ResultType.EMPTY,
    })
  chatUpdates = this.userUpdates
  chatSnapshot: RpcHandler = () => ({
    oneofKind: "getChat",
    getChat: {
      chat: sidecars().chats[0],
      dialog: sidecars().dialogs[0],
      pinnedMessageIds: [],
      messages: [],
      anchorMessage: {
        id: 102n,
        chatId: 10n,
        peerId: peer,
        fromId: 7n,
        out: false,
        date: 1_002n,
        message: "Old anchor",
      },
    },
  })
  chatHistory: RpcHandler = () => ({
    oneofKind: "getChatHistory",
    getChatHistory: {
      messages: [
        {
          id: 103n,
          chatId: 10n,
          peerId: peer,
          fromId: 7n,
          out: false,
          date: 1_003n,
          message: "Old history",
        },
      ],
    },
  })

  async callRpc(method: Method, input: RpcCall["input"]) {
    this.calls.push({ method, input })
    if (method === Method.GET_UPDATES_STATE) return this.updatesState(input)
    if (method === Method.GET_CHAT) return this.chatSnapshot(input)
    if (method === Method.GET_CHAT_HISTORY) return this.chatHistory(input)
    if (method !== Method.GET_UPDATES || input.oneofKind !== "getUpdates") {
      throw new Error(`Unexpected RPC ${method}`)
    }
    return input.getUpdates.bucket?.type.oneofKind === "user"
      ? this.userUpdates(input)
      : this.chatUpdates(input)
  }
}

const createContext = async (open = true) => {
  const namespace = `sync-admission-${crypto.randomUUID()}`
  const db = new Db({ autoHydrate: false, storageNamespace: namespace })
  await db.commit(() => {
    applyUpdateSidecars(db, sidecars())
  })
  const storage = new DbSyncStorage(db)
  const client = new FakeSyncClient()
  const engine = new SyncEngine({
    db,
    storage,
    client,
    now: () => 2_000,
    retryDelaysMs: [60_000],
  })
  if (open) {
    await engine.connectionOpened()
    await engine.idle()
  }
  return { namespace, db, storage, client, engine }
}
type Context = Awaited<ReturnType<typeof createContext>>

const replayUser = async (
  context: Context,
  updates: Update[],
  snapshot?: UpdateSidecars,
) => {
  const targetSeq = updates.at(-1)!.seq!
  const committed = deferred<void>()
  const commit = context.storage.commitBucketState.bind(context.storage)
  const observe = vi
    .spyOn(context.storage, "commitBucketState")
    .mockImplementation(async (...args) => {
      const result = await commit(...args)
      if (result && args[0].kind === "user" && args[1].seq >= targetSeq)
        committed.resolve()
      return result
    })
  context.client.userUpdates = () => page(updates, { sidecars: snapshot })
  try {
    await context.engine.processPush([
      Update.create({
        update: {
          oneofKind: "userHasNewUpdates",
          userHasNewUpdates: { updateSeq: targetSeq },
        },
      }),
    ])
    await committed.promise
  } finally {
    observe.mockRestore()
  }
  expect((await context.storage.getBucketState({ kind: "user" })).seq).toBe(
    targetSeq,
  )
}

const reopened = async (context: Context) => {
  await context.db.flushPersistence()
  const db = new Db({ autoHydrate: false, storageNamespace: context.namespace })
  await db.hydrateKinds([
    DbObjectKind.Chat,
    DbObjectKind.Dialog,
    DbObjectKind.Message,
  ])
  return db
}

const expectAbsent = (db: Db) => {
  expect(db.get(db.ref(DbObjectKind.Chat, exactChatId))).toBeUndefined()
  expect(db.get(db.ref(DbObjectKind.Dialog, exactDialogId))).toBeUndefined()
  expect(
    db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message),
  ).toEqual([])
}

const expectRejoined = (db: Db) => {
  expect(db.get(db.ref(DbObjectKind.Chat, exactChatId))?.title).toBe(
    "Rejoined thread",
  )
  expect(db.get(db.ref(DbObjectKind.Dialog, exactDialogId))).toMatchObject({
    readMaxId: messageId(20),
    unreadCount: 0,
    unreadMark: false,
  })
  expect(
    db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message),
  ).toEqual([])
}

const responseStages = ["getUpdates", "getChat", "getChatHistory"] as const
const blockOldChatResponse = (
  client: FakeSyncClient,
  stage: (typeof responseStages)[number],
) => {
  const requested = deferred<void>()
  const response = deferred<RpcResult["result"]>()
  let oldResult: RpcResult["result"]
  if (stage === "getUpdates") {
    oldResult = page([newMessage()], { sidecars: sidecars() })
    client.chatUpdates = () => {
      requested.resolve()
      return response.promise
    }
  } else {
    client.chatUpdates = () =>
      page([], {
        seq: 500n,
        date: 1_500n,
        resultType: GetUpdatesResult_ResultType.TOO_LONG,
      })
    if (stage === "getChat") {
      oldResult = client.chatSnapshot({
        oneofKind: undefined,
      }) as RpcResult["result"]
      client.chatSnapshot = () => {
        requested.resolve()
        return response.promise
      }
    } else {
      oldResult = client.chatHistory({
        oneofKind: undefined,
      }) as RpcResult["result"]
      client.chatHistory = () => {
        requested.resolve()
        return response.promise
      }
    }
  }
  return {
    requested: requested.promise,
    release: () => response.resolve(oldResult),
  }
}

describe("SyncEngine delayed response admission", () => {
  beforeEach(() => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("applies the fresh unread sidecar from each page of one catchup", async () => {
    const context = await createContext()
    const starts: bigint[] = []
    context.client.chatUpdates = (input) => {
      const startSeq = input.getUpdates.startSeq
      starts.push(startSeq)
      if (startSeq === 0n) {
        return page([newMessage(1, 21)], {
          final: false,
          sidecars: sidecars("Old thread", 5n, 1),
        })
      }
      if (startSeq === 1n) {
        return page([newMessage(2, 22)], {
          sidecars: sidecars("Old thread", 5n, 2),
        })
      }
      throw new Error(`Unexpected catchup start ${startSeq}`)
    }
    try {
      await context.engine.processPush([chatHint(2)])
      await context.engine.idle()
      expect(starts).toEqual([0n, 1n])
      const assertUnread = (db: Db) => {
        expect(db.get(db.ref(DbObjectKind.Dialog, exactDialogId))).toMatchObject({
          readMaxId: messageId(5),
          unreadCount: 2,
          unreadMark: true,
        })
      }
      assertUnread(context.db)
      expect((await context.storage.getBucketState(chatKey)).seq).toBe(2)
      expect(context.db.get(context.db.ref(DbObjectKind.Message, messageKey(exactChatId, messageId(22))))?.message).toBe("Message 22")
      const restarted = await reopened(context)
      try {
        assertUnread(restarted)
      } finally {
        await restarted.closePersistence()
      }
    } finally {
      await context.engine.stop()
      await context.db.closePersistence()
    }
  })

  it("fetches authorized user sidecars for an unsequenced access grant push", async () => {
    const context = await createContext()
    const grantedPeer = {
      type: { oneofKind: "chat" as const, chat: { chatId: 99n } },
    }
    const grantedChatId = chatId(99)
    const grantedDialogId = getDialogId({ peerThreadId: grantedChatId })
    const snapshot = UpdateSidecars.create({
      chats: [{ id: 99n, peerId: grantedPeer, title: "Granted thread" }],
      dialogs: [{ chatId: 99n, peer: grantedPeer, open: true }],
    })
    const grant = Update.create({
      seq: 1,
      date: 1_031n,
      update: {
        oneofKind: "userAddedToChat",
        userAddedToChat: { chatId: 99n },
      },
    })
    context.client.userUpdates = () => page([grant], { sidecars: snapshot })
    try {
      expect(context.db.get(context.db.ref(DbObjectKind.Chat, grantedChatId))).toBeUndefined()
      await context.engine.processPush([Update.create({
        update: {
          oneofKind: "userAddedToChat",
          userAddedToChat: { chatId: 99n },
        },
      })])
      await context.engine.idle()
      const assertGranted = (db: Db) => {
        expect(db.get(db.ref(DbObjectKind.Chat, grantedChatId))?.title).toBe("Granted thread")
        expect(db.get(db.ref(DbObjectKind.Dialog, grantedDialogId))).toMatchObject({
          chatId: grantedChatId,
          peerThreadId: grantedChatId,
          open: true,
        })
      }
      assertGranted(context.db)
      expect((await context.storage.getBucketState({ kind: "user" })).seq).toBe(1)
      const restarted = await reopened(context)
      try {
        assertGranted(restarted)
      } finally {
        await restarted.closePersistence()
      }
    } finally {
      await context.engine.stop()
      await context.db.closePersistence()
    }
  })

  it("preserves a confirmed read frontier against older delayed chat sidecars", async () => {
    const context = await createContext()
    const blocked = blockOldChatResponse(context.client, "getUpdates")
    try {
      await context.engine.processPush([chatHint()])
      await blocked.requested
      const transaction = new ReadMessagesTransaction({
        peerId: peer,
        maxId: messageId(20),
      })
      await context.db.commit(() => {
        transaction.optimistic(context.db)
        transaction.apply(
          {
            oneofKind: "readMessages",
            readMessages: {
              updates: [readUpdate(0)],
            },
          },
          context.db,
        )
      })
      await replayUser(context, [readUpdate(1)])
      blocked.release()
      await context.engine.idle()
      const assertRead = (db: Db) =>
        expect(
          db.get(db.ref(DbObjectKind.Dialog, exactDialogId)),
        ).toMatchObject({
          readMaxId: messageId(20),
          unreadCount: 0,
          unreadMark: false,
        })
      assertRead(context.db)
      const restarted = await reopened(context)
      try {
        assertRead(restarted)
      } finally {
        await restarted.closePersistence()
      }
      expect((await context.storage.getBucketState(chatKey)).seq).toBe(1)
    } finally {
      blocked.release()
      await context.engine.stop()
      await context.db.closePersistence()
    }
  })

  it("preserves a newer unread mark when delayed sidecars have the same read frontier", async () => {
    const context = await createContext()
    await context.db.commit(() => {
      applyUpdateSidecars(context.db, sidecars("Old thread", 20n, 0))
    })
    const requested = deferred<void>()
    const response = deferred<RpcResult["result"]>()
    const oldPage = page([newMessage()], {
      sidecars: sidecars("Old thread", 20n, 0),
    })
    context.client.chatUpdates = () => {
      requested.resolve()
      return response.promise
    }
    try {
      await context.engine.processPush([chatHint()])
      await requested.promise
      await replayUser(context, [
        Update.create({
          seq: 1,
          date: 1_020n,
          update: {
            oneofKind: "markAsUnread",
            markAsUnread: { peerId: peer, unreadMark: true },
          },
        }),
      ])
      response.resolve(oldPage)
      await context.engine.idle()
      const assertUnread = (db: Db) =>
        expect(
          db.get(db.ref(DbObjectKind.Dialog, exactDialogId)),
        ).toMatchObject({
          readMaxId: messageId(20),
          unreadCount: 0,
          unreadMark: true,
        })
      assertUnread(context.db)
      const restarted = await reopened(context)
      try {
        assertUnread(restarted)
      } finally {
        await restarted.closePersistence()
      }
    } finally {
      response.resolve(oldPage)
      await context.engine.stop()
      await context.db.closePersistence()
    }
  })

  it("keeps the pending chat target when an ordinary user read page refreshes its Chat sidecar", async () => {
    const context = await createContext()
    const requested = deferred<void>()
    const response = deferred<RpcResult["result"]>()
    const catchupPage = page([newMessage(100, 100)], {
      seq: 100n,
      skippedSequences: Array.from({ length: 99 }, (_, index) => ({
        seq: BigInt(index + 1),
        reason: SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET,
      })),
      sidecars: sidecars(),
    })
    let calls = 0
    context.client.chatUpdates = () => {
      calls += 1
      if (calls === 1) {
        requested.resolve()
        return response.promise
      }
      return catchupPage
    }
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
    try {
      await context.engine.processPush([chatHint(100)])
      await requested.promise
      await replayUser(
        context,
        [readUpdate(1)],
        sidecars("Read refresh", 20n, 0),
      )
      response.resolve(catchupPage)
      await context.engine.idle()
      expect(calls).toBe(1)
      expect((await context.storage.getBucketState(chatKey)).seq).toBe(100)
      expect(
        context.db.get(
          context.db.ref(
            DbObjectKind.Message,
            messageKey(exactChatId, messageId(100)),
          ),
        )?.message,
      ).toBe("Message 100")
      expect(
        context.db.get(context.db.ref(DbObjectKind.Dialog, exactDialogId)),
      ).toMatchObject({
        readMaxId: messageId(20),
        unreadCount: 0,
        unreadMark: false,
      })
    } finally {
      response.resolve(catchupPage)
      await context.engine.stop()
      await context.db.closePersistence()
      vi.useRealTimers()
    }
  })

  it.each(responseStages)(
    "rejects a delayed %s response after committed access removal",
    async (stage) => {
      const context = await createContext()
      const blocked = blockOldChatResponse(context.client, stage)
      try {
        await context.engine.processPush([
          chatHint(stage === "getUpdates" ? 1 : 500),
        ])
        await blocked.requested
        await replayUser(context, [removed()])
        expectAbsent(context.db)
        blocked.release()
        await context.engine.idle()
        expectAbsent(context.db)
        expect(await context.storage.getBucketState(chatKey)).toEqual({
          seq: 0,
          date: 0,
        })
        const restarted = await reopened(context)
        try {
          expectAbsent(restarted)
        } finally {
          await restarted.closePersistence()
        }
      } finally {
        blocked.release()
        await context.engine.stop()
        await context.db.closePersistence()
      }
    },
  )

  it.each(responseStages)(
    "rejects an old %s response after removal and rejoin in one user page",
    async (stage) => {
      const context = await createContext()
      const blocked = blockOldChatResponse(context.client, stage)
      const targetSeq = stage === "getUpdates" ? 1 : 500
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
      try {
        await context.engine.processPush([chatHint(targetSeq)])
        await blocked.requested
        await replayUser(
          context,
          [removed(), added()],
          sidecars("Rejoined thread", 20n, 0),
        )
        expectRejoined(context.db)
        blocked.release()
        await context.engine.idle()
        expectRejoined(context.db)
        expect(await context.storage.getBucketState(chatKey)).toEqual({
          seq: 0,
          date: 0,
        })
        const restarted = await reopened(context)
        try {
          expectRejoined(restarted)
        } finally {
          await restarted.closePersistence()
        }
        context.client.chatUpdates = () =>
          page([newMessage(targetSeq, 201)], {
            seq: BigInt(targetSeq),
            skippedSequences: Array.from(
              { length: targetSeq - 1 },
              (_, index) => ({
                seq: BigInt(index + 1),
                reason: SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET,
              }),
            ),
          })
        await context.engine.processPush([chatHint(targetSeq)])
        await vi.advanceTimersByTimeAsync(60_000)
        await context.engine.idle()
        expect(
          context.db.get(
            context.db.ref(
              DbObjectKind.Message,
              messageKey(exactChatId, messageId(201)),
            ),
          )?.message,
        ).toBe("Message 201")
        expect((await context.storage.getBucketState(chatKey)).seq).toBe(
          targetSeq,
        )
      } finally {
        blocked.release()
        await context.engine.stop()
        await context.db.closePersistence()
        vi.useRealTimers()
      }
    },
  )

  it("does not materialize or advance a delayed page from an interrupted connection", async () => {
    const context = await createContext()
    const blocked = blockOldChatResponse(context.client, "getUpdates")
    try {
      await context.engine.processPush([chatHint()])
      await blocked.requested
      context.engine.connectionInterrupted()
      blocked.release()
      await context.engine.idle()
      expect(
        context.db.get(
          context.db.ref(
            DbObjectKind.Message,
            messageKey(exactChatId, messageId(101)),
          ),
        ),
      ).toBeUndefined()
      expect(await context.storage.getBucketState(chatKey)).toEqual({
        seq: 0,
        date: 0,
      })
      const restarted = await reopened(context)
      try {
        expect(
          restarted.queryCollection(
            DbQueryPlanType.Objects,
            DbObjectKind.Message,
          ),
        ).toEqual([])
      } finally {
        await restarted.closePersistence()
      }
    } finally {
      blocked.release()
      await context.engine.stop()
      await context.db.closePersistence()
    }
  })

  it("drains delayed discovery when stopping the connection", async () => {
    const context = await createContext(false)
    const requested = deferred<void>()
    const response = deferred<RpcResult["result"]>()
    const result: RpcResult["result"] = {
      oneofKind: "getUpdatesState",
      getUpdatesState: {
        date: 1_000n,
        updatesFound: false,
      },
    }
    context.client.updatesState = () => {
      requested.resolve()
      return response.promise
    }
    try {
      await context.engine.connectionOpened()
      await requested.promise
      const stopping = context.engine.stop()
      response.resolve(result)
      await stopping
      await context.engine.idle()
    } finally {
      response.resolve(result)
      await context.engine.stop()
      await context.db.closePersistence()
    }
  })
})
