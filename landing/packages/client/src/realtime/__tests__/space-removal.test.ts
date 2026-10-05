import {
  GetChatsResult,
  GetUpdatesResult_ResultType,
  Method,
  ServerProtocolMessage,
  Update,
  UpdateSidecars,
  type RpcCall,
  type RpcResult,
} from "@inline-chat/protocol/core"
import { chatId, dialogId, messageId, spaceId, userId } from "@inline/ids"
import { IDBFactory, IDBKeyRange } from "fake-indexeddb"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { AuthStore } from "../../auth/auth-store"
import { Db } from "../../database"
import { DbObjectKind, messageDraftKey, messageKey } from "../../database/models"
import { createIndexedDbPersistenceStore } from "../../database/storage"
import { DbQueryPlanType } from "../../database/types"
import { RealtimeClient } from "../realtime"
import { DbSyncStorage } from "../sync/db-sync-storage"
import { SyncEngine, type SyncEngineOptions, type SyncRpcClient } from "../sync/sync-engine"
import { applyUpdates } from "../updates/apply-updates"
import { GetChatsTransaction } from "../transactions/get-chats"
import { MockTransport } from "../transport/mock-transport"

const targetSpaceId = spaceId(17)
const currentUserId = userId(7)
const removedChats = [chatId(801), chatId(803), chatId(804), chatId(805)]
const keptChat = chatId(802)
const draftKey = messageDraftKey({ peerKind: "chat", peerThreadId: chatId(803) })
const metadata = [DbObjectKind.Space, DbObjectKind.Chat, DbObjectKind.Dialog, DbObjectKind.MessageDraft]
const applyForCurrentUser = applyUpdates
type UpdatesInput = Extract<RpcCall["input"], { oneofKind: "getUpdates" }>
type UpdatesReply = (input: UpdatesInput) => RpcResult["result"] | Promise<RpcResult["result"]>
type RpcReply = (input: RpcCall["input"]) => RpcResult["result"] | Promise<RpcResult["result"]>

const deferred = <T>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((settle) => {
    resolve = settle
  })
  return { promise, resolve }
}

const wireUpdate = (update: Update) => Update.fromBinary(Update.toBinary(update))
const removed = (options: { seq?: number; memberId?: bigint; user?: bigint } = {}) =>
  wireUpdate(
    Update.create({
      seq: options.seq ?? 1,
      date: 100n,
      update: {
        oneofKind: "spaceMemberDelete",
        spaceMemberDelete: { spaceId: 17n, userId: options.user ?? 7n, memberId: options.memberId },
      },
    }),
  )

const joined = (seq = 0, memberId = 1_000n, name = "Private Space") =>
  wireUpdate(
    Update.create({
      seq,
      date: BigInt(100 + seq),
      update: {
        oneofKind: "joinSpace",
        joinSpace: {
          space: { id: 17n, name, creator: false, date: 1n },
          member: { id: memberId, spaceId: 17n, userId: 7n, date: BigInt(100 + seq), canAccessPublicChats: true },
        },
      },
    }),
  )

const seed = async (db: Db, retainJoin = true) => {
  await db.commit(() => {
    db.insert({ kind: DbObjectKind.Space, id: targetSpaceId, name: "Private Space", creator: false, date: 1 })
    db.insert({ kind: DbObjectKind.Space, id: spaceId(18), name: "Other Space", creator: false, date: 1 })
    for (const id of [...removedChats, keptChat]) {
      const parentChatId = id === chatId(803) ? chatId(801) : id === chatId(804) ? chatId(803) : undefined
      db.insert({
        kind: DbObjectKind.Chat,
        id,
        title: `chat ${id}`,
        parentChatId,
        spaceId: parentChatId == null ? (id === keptChat ? spaceId(18) : targetSpaceId) : undefined,
      })
      db.insert({ kind: DbObjectKind.Dialog, id: dialogId(-BigInt(id)), chatId: id, peerThreadId: id })
      db.insert({
        kind: DbObjectKind.Message,
        id: messageKey(id, messageId(1)),
        messageId: messageId(1),
        chatId: id,
        fromId: currentUserId,
        message: "Stored private history",
      })
    }
    db.insert({
      kind: DbObjectKind.MessageDraft,
      id: draftKey,
      peerKind: "chat",
      peerThreadId: chatId(803),
      text: "unsent local draft",
      revision: 1,
      updatedAt: 100,
    })
    if (retainJoin) applyForCurrentUser(db, [joined()], "realtime", { currentUserId })
  })
}

const reopen = async (namespace: string) => {
  const store = createIndexedDbPersistenceStore(namespace)
  if (!store) throw new Error("IndexedDB persistence unavailable")
  const db = new Db({ autoHydrate: false, persistenceStore: store })
  await db.hydrateKinds(metadata)
  const storage = new DbSyncStorage(db)
  await storage.initialize()
  return { namespace, store, db, storage }
}

const fixture = async (retainJoin = true) => {
  const namespace = `space-removal-${crypto.randomUUID()}`
  const db = new Db({ autoHydrate: false, storageNamespace: namespace })
  await seed(db, retainJoin)
  await db.closePersistence()
  return await reopen(namespace)
}
type Context = Awaited<ReturnType<typeof fixture>>

const commitUser = async (context: Context, updates: Update[]) => {
  const final = updates.at(-1)!
  expect(
    await context.storage.commitBucketState(
      { kind: "user" },
      {
        seq: final.seq!,
        date: Number(final.date),
      },
      () => {
        applyForCurrentUser(context.db, updates, "syncCatchup", { currentUserId, bucketKind: "user" })
      },
    ),
  ).toBe(true)
}

const expectRemoved = (db: Db) => {
  expect(db.get(db.ref(DbObjectKind.Space, targetSpaceId))).toBeUndefined()
  for (const id of removedChats) {
    expect(db.get(db.ref(DbObjectKind.Chat, id))).toBeUndefined()
    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-BigInt(id))))).toBeUndefined()
    expect(db.get(db.ref(DbObjectKind.Message, messageKey(id, messageId(1))))).toBeUndefined()
  }
  expect(db.get(db.ref(DbObjectKind.Chat, keptChat))).toBeDefined()
  expect(db.get(db.ref(DbObjectKind.Space, spaceId(18)))).toBeDefined()
  expect(db.get(db.ref(DbObjectKind.MessageDraft, draftKey))?.text).toBe("unsent local draft")
}

const emptyPage: UpdatesReply = (input) => ({
  oneofKind: "getUpdates",
  getUpdates: {
    updates: [],
    seq: input.getUpdates.startSeq,
    date: 100n,
    final: true,
    resultType: GetUpdatesResult_ResultType.EMPTY,
    skippedSequences: [],
  },
})

const updatesPage = (updates: Update[], sidecars?: UpdateSidecars): RpcResult["result"] => ({
  oneofKind: "getUpdates",
  getUpdates: {
    updates,
    seq: BigInt(updates.at(-1)!.seq!),
    date: updates.at(-1)!.date!,
    final: true,
    resultType: GetUpdatesResult_ResultType.SLICE,
    skippedSequences: [],
    sidecars,
  },
})

const snapshot = (rejoined = false) =>
  UpdateSidecars.create({
    spaces: [{ id: 17n, name: rejoined ? "Rejoined Space" : "Old Space", creator: false, date: 1n }],
    chats: [
      {
        id: 801n,
        spaceId: 17n,
        title: rejoined ? "Rejoined chat" : "Old chat",
        peerId: {
          type: { oneofKind: "chat", chat: { chatId: 801n } },
        },
      },
    ],
    dialogs: [
      {
        chatId: 801n,
        spaceId: 17n,
        open: true,
        peer: {
          type: { oneofKind: "chat", chat: { chatId: 801n } },
        },
      },
    ],
  })

const oldMessage = () =>
  wireUpdate(
    Update.create({
      seq: 1,
      date: 100n,
      update: {
        oneofKind: "newMessage",
        newMessage: {
          message: {
            id: 500n,
            chatId: 801n,
            fromId: 9n,
            out: false,
            date: 100n,
            message: "Old in-flight history",
            peerId: { type: { oneofKind: "chat", chat: { chatId: 801n } } },
          },
        },
      },
    }),
  )

const otherMemberAdded = () =>
  wireUpdate(
    Update.create({
      seq: 1,
      date: 100n,
      update: {
        oneofKind: "spaceMemberAdd",
        spaceMemberAdd: {
          member: { id: 900n, spaceId: 17n, userId: 9n, date: 100n, canAccessPublicChats: true },
        },
      },
    }),
  )

const catchupHint = (bucket: "space" | "chat") =>
  wireUpdate(
    Update.create({
      update:
        bucket === "space"
          ? { oneofKind: "spaceHasNewUpdates", spaceHasNewUpdates: { spaceId: 17n, updateSeq: 1 } }
          : {
              oneofKind: "chatHasNewUpdates",
              chatHasNewUpdates: {
                chatId: 801n,
                peerId: { type: { oneofKind: "chat", chat: { chatId: 801n } } },
                updateSeq: 1,
              },
            },
    }),
  )

class EmptySyncClient implements SyncRpcClient {
  readonly calls: Array<{ method: Method; input: RpcCall["input"] }> = []
  userUpdates = emptyPage
  otherUpdates = emptyPage
  chatSnapshot: RpcReply = () => {
    throw new Error("Unexpected GET_CHAT")
  }
  chatHistory: RpcReply = () => {
    throw new Error("Unexpected GET_CHAT_HISTORY")
  }

  async callRpc(method: Method, input: RpcCall["input"]): Promise<RpcResult["result"]> {
    this.calls.push({ method, input })
    if (method === Method.GET_UPDATES_STATE) {
      return { oneofKind: "getUpdatesState", getUpdatesState: { date: 100n, updatesFound: false } }
    }
    if (method === Method.GET_CHAT) return this.chatSnapshot(input)
    if (method === Method.GET_CHAT_HISTORY) return this.chatHistory(input)
    if (method !== Method.GET_UPDATES || input.oneofKind !== "getUpdates") throw new Error(`Unexpected RPC ${method}`)
    return input.getUpdates.bucket?.type.oneofKind === "user" ? this.userUpdates(input) : this.otherUpdates(input)
  }
}

const openEngine = async (context: Context) => {
  const client = new EmptySyncClient()
  const options: SyncEngineOptions = {
    db: context.db,
    storage: context.storage,
    client,
    getCurrentUserId: () => currentUserId,
    now: () => 1_000,
    retryDelaysMs: [60_000],
  }
  const engine = new SyncEngine(options)
  await engine.connectionOpened()
  await engine.idle()
  return { engine, client }
}

const replayThroughEngine = async (
  context: Context,
  engine: SyncEngine,
  client: EmptySyncClient,
  updates: Update[],
  sidecars?: UpdateSidecars,
) => {
  const seq = updates.at(-1)!.seq!
  const committed = deferred<void>()
  const commit = context.storage.commitBucketState.bind(context.storage)
  const observe = vi.spyOn(context.storage, "commitBucketState").mockImplementation(async (...args) => {
    const result = await commit(...args)
    if (result && args[0].kind === "user" && args[1].seq >= seq) committed.resolve()
    return result
  })
  const previous = client.userUpdates
  client.userUpdates = () => updatesPage(updates, sidecars)
  try {
    await engine.processPush([
      wireUpdate(
        Update.create({
          update: {
            oneofKind: "userHasNewUpdates",
            userHasNewUpdates: { updateSeq: seq },
          },
        }),
      ),
    ])
    await committed.promise
  } finally {
    client.userUpdates = previous
    observe.mockRestore()
  }
}

describe("effective self Space removal", () => {
  beforeEach(() => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
  })
  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("removes self Space state when its ordered user cursor commits", async () => {
    const db = new Db({ autoHydrate: false, storageNamespace: `space-removal-${crypto.randomUUID()}` })
    const storage = new DbSyncStorage(db)
    try {
      await db.commit(() =>
        db.insert({
          kind: DbObjectKind.Space,
          id: targetSpaceId,
          name: "Private Space",
          creator: false,
          date: 1,
        }),
      )
      expect(
        await storage.commitBucketState({ kind: "user" }, { seq: 1, date: 100 }, () => {
          applyForCurrentUser(db, [removed()], "syncCatchup", { currentUserId, bucketKind: "user" })
        }),
      ).toBe(true)
      expect(await storage.getBucketState({ kind: "user" })).toEqual({ seq: 1, date: 100 })
      expect(db.get(db.ref(DbObjectKind.Space, targetSpaceId))).toBeUndefined()
    } finally {
      await db.closePersistence()
    }
  })

  it("removes all known Space chats and inherited descendants, including unloaded stored history, while retaining drafts", async () => {
    const context = await fixture()
    try {
      expect(context.db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message)).toEqual([])
      await commitUser(context, [removed()])
      expectRemoved(context.db)
      await context.db.closePersistence()
      const restarted = await reopen(context.namespace)
      try {
        await restarted.db.hydrateKinds([DbObjectKind.Message])
        expectRemoved(restarted.db)
        expect(
          restarted.db.get(restarted.db.ref(DbObjectKind.Message, messageKey(keptChat, messageId(1))))?.message,
        ).toBe("Stored private history")
        expect((await restarted.storage.getBucketState({ kind: "user" })).seq).toBe(1)
      } finally {
        await restarted.db.closePersistence()
      }
    } finally {
      await context.db.closePersistence()
    }
  })

  it.each(["user", "direct"] as const)(
    "retains all local Space data when another user is removed through %s context",
    async (bucket) => {
      const context = await fixture()
      try {
        if (bucket === "user") {
          await commitUser(context, [removed({ user: 8n })])
        } else {
          await context.db.commit(() =>
            applyForCurrentUser(context.db, [removed({ user: 8n, seq: 0, memberId: 1_000n })], "realtime", {
              currentUserId,
            }),
          )
        }
        expect(context.db.get(context.db.ref(DbObjectKind.Space, targetSpaceId))).toBeDefined()
        for (const id of removedChats) {
          expect(context.db.get(context.db.ref(DbObjectKind.Chat, id))).toBeDefined()
          expect(context.db.get(context.db.ref(DbObjectKind.Dialog, dialogId(-BigInt(id))))).toBeDefined()
        }
        await context.db.hydrateKinds([DbObjectKind.Message])
        expect(context.db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message)).toHaveLength(5)
      } finally {
        await context.db.closePersistence()
      }
    },
  )

  it("replays a durable user removal before applying a matching live eviction after reopen", async () => {
    const context = await fixture()
    const deferred = context.store.collection(DbObjectKind.DeferredUpdate)
    const scan = vi.spyOn(deferred, "getAll")
    const indexed = vi.spyOn(deferred, "getDeferredUpdatesByTargetKeys")
    const { engine, client } = await openEngine(context)
    client.userUpdates = () => updatesPage([removed()])
    try {
      expect(context.db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.DeferredUpdate)).toEqual([])
      await engine.processPush([removed({ seq: 0, memberId: 1_000n })])
      await engine.idle()
      expectRemoved(context.db)
      expect(scan).not.toHaveBeenCalled()
      expect(indexed).not.toHaveBeenCalled()
      expect((await context.storage.getBucketState({ kind: "user" })).seq).toBe(1)
      await engine.stop()
      await context.db.closePersistence()
      const restarted = await reopen(context.namespace)
      try {
        await restarted.db.hydrateKinds([DbObjectKind.Message])
        expectRemoved(restarted.db)
      } finally {
        await restarted.db.closePersistence()
      }
    } finally {
      await engine.stop()
      await context.db.closePersistence()
    }
  })

  it("preserves a newer rejoin against a late immediate removal for the old membership after close and reopen", async () => {
    const context = await fixture()
    try {
      await commitUser(context, [removed()])
      await commitUser(context, [removed()])
      expectRemoved(context.db)
      await commitUser(context, [joined(2, 2_000n, "Rejoined Space")])
      await context.db.commit(() => {
        context.db.insert({ kind: DbObjectKind.Chat, id: chatId(801), spaceId: targetSpaceId, title: "Rejoined chat" })
        context.db.insert({
          kind: DbObjectKind.Dialog,
          id: dialogId(-801),
          chatId: chatId(801),
          peerThreadId: chatId(801),
        })
        context.db.storeNonResidentObject({
          kind: DbObjectKind.Message,
          id: messageKey(chatId(801), messageId(2)),
          messageId: messageId(2),
          chatId: chatId(801),
          fromId: currentUserId,
          message: "Fresh authorized history",
        })
      })
      await context.db.closePersistence()
      const restarted = await reopen(context.namespace)
      const deferred = restarted.store.collection(DbObjectKind.DeferredUpdate)
      const scan = vi.spyOn(deferred, "getAll")
      const indexed = vi.spyOn(deferred, "getDeferredUpdatesByTargetKeys")
      const { engine } = await openEngine(restarted)
      try {
        await engine.processPush([removed({ seq: 0, memberId: 1_000n })])
        await engine.idle()
        expect(restarted.db.get(restarted.db.ref(DbObjectKind.Space, targetSpaceId))?.name).toBe("Rejoined Space")
        expect(restarted.db.get(restarted.db.ref(DbObjectKind.Chat, chatId(801)))?.title).toBe("Rejoined chat")
        expect(restarted.db.get(restarted.db.ref(DbObjectKind.Dialog, dialogId(-801)))).toBeDefined()
        await restarted.db.hydrateKinds([DbObjectKind.Message])
        expect(
          restarted.db.get(restarted.db.ref(DbObjectKind.Message, messageKey(chatId(801), messageId(1)))),
        ).toBeUndefined()
        expect(
          restarted.db.get(restarted.db.ref(DbObjectKind.Message, messageKey(chatId(801), messageId(2))))?.message,
        ).toBe("Fresh authorized history")
        expect((await restarted.storage.getBucketState({ kind: "user" })).seq).toBe(2)
        expect(scan).not.toHaveBeenCalled()
        expect(indexed).not.toHaveBeenCalled()
      } finally {
        await engine.stop()
        await restarted.db.closePersistence()
      }
    } finally {
      await context.db.closePersistence()
    }
  })

  it("requests ordered user replay without purging when an immediate removal has no retained membership generation", async () => {
    const context = await fixture(false)
    const { engine, client } = await openEngine(context)
    const before = client.calls.filter((call) => call.method === Method.GET_UPDATES).length
    try {
      await engine.processPush([removed({ seq: 0, memberId: 1_000n })])
      await engine.idle()
      expect(context.db.get(context.db.ref(DbObjectKind.Space, targetSpaceId))).toBeDefined()
      expect(context.db.get(context.db.ref(DbObjectKind.Chat, chatId(801)))).toBeDefined()
      expect(client.calls.filter((call) => call.method === Method.GET_UPDATES).length).toBeGreaterThan(before)
    } finally {
      await engine.stop()
      await context.db.closePersistence()
    }
  })

  it("preserves a current GET_CHATS grant when an old retained join matches a late live eviction", async () => {
    const context = await fixture()
    const current = snapshot(true)
    try {
      await context.db.commit(() => {
        new GetChatsTransaction().apply(
          {
            oneofKind: "getChats",
            getChats: GetChatsResult.fromBinary(
              GetChatsResult.toBinary(
                GetChatsResult.create({
                  ...current,
                  messages: [{ id: 2n, chatId: 801n, fromId: 7n, message: "Current authorized history" }],
                }),
              ),
            ),
          },
          context.db,
        )
      })
      await context.db.closePersistence()
      const restarted = await reopen(context.namespace)
      const { engine, client } = await openEngine(restarted)
      const before = client.calls.length
      try {
        await engine.processPush([removed({ seq: 0, memberId: 1_000n })])
        await engine.idle()
        expect(
          client.calls
            .slice(before)
            .some(
              (call) =>
                call.input.oneofKind === "getUpdates" && call.input.getUpdates.bucket?.type.oneofKind === "user",
            ),
        ).toBe(true)
        expect(restarted.db.get(restarted.db.ref(DbObjectKind.Space, targetSpaceId))?.name).toBe("Rejoined Space")
        expect(restarted.db.get(restarted.db.ref(DbObjectKind.Chat, chatId(801)))?.title).toBe("Rejoined chat")
        expect(
          await restarted.store.collection(DbObjectKind.Message).get(messageKey(chatId(801), messageId(2))),
        ).toMatchObject({ message: "Current authorized history" })
        expect((await restarted.storage.getBucketState({ kind: "user" })).seq).toBe(0)
      } finally {
        await engine.stop()
        await restarted.db.closePersistence()
      }
    } finally {
      await context.db.closePersistence()
    }
  })

  it("replays an eviction requested while an older user latest response is in flight", async () => {
    const context = await fixture()
    const { engine, client } = await openEngine(context)
    const requested = deferred<UpdatesInput>()
    const response = deferred<RpcResult["result"]>()
    let userPages = 0
    client.userUpdates = (input) => {
      userPages += 1
      if (userPages === 1) {
        requested.resolve(input)
        return response.promise
      }
      return updatesPage([removed()])
    }
    try {
      await engine.processPush([removed({ seq: 0, memberId: 999n })])
      const priorRequest = await requested.promise
      await engine.processPush([removed({ seq: 0, memberId: 1_000n })])
      response.resolve(await emptyPage(priorRequest))
      await engine.idle()
      expect(userPages).toBe(2)
      expectRemoved(context.db)
      expect((await context.storage.getBucketState({ kind: "user" })).seq).toBe(1)
      await engine.stop()
      await context.db.closePersistence()
      const restarted = await reopen(context.namespace)
      try {
        await restarted.db.hydrateKinds([DbObjectKind.Message])
        expectRemoved(restarted.db)
      } finally {
        await restarted.db.closePersistence()
      }
    } finally {
      response.resolve(updatesPage([removed()]))
      await engine.stop()
      await context.db.closePersistence()
    }
  })

  it.each(["space", "chat"] as const)(
    "rejects a delayed %s bucket snapshot across committed self removal",
    async (bucket) => {
      const context = await fixture()
      const { engine, client } = await openEngine(context)
      const requested = deferred<void>()
      const response = deferred<RpcResult["result"]>()
      const oldPage = updatesPage([bucket === "space" ? otherMemberAdded() : oldMessage()], snapshot())
      client.otherUpdates = () => {
        requested.resolve()
        return response.promise
      }
      try {
        await engine.processPush([catchupHint(bucket)])
        await requested.promise
        await replayThroughEngine(context, engine, client, [removed()])
        expectRemoved(context.db)
        response.resolve(oldPage)
        await engine.idle()
        expectRemoved(context.db)
        expect((await context.storage.getBucketState({ kind: "user" })).seq).toBe(1)
        expect(
          await context.store.collection(DbObjectKind.Message).get(messageKey(chatId(801), messageId(500))),
        ).toBeUndefined()
        await engine.stop()
        await context.db.closePersistence()
        const restarted = await reopen(context.namespace)
        try {
          await restarted.db.hydrateKinds([DbObjectKind.Message])
          expectRemoved(restarted.db)
          expect(restarted.db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message)).toHaveLength(1)
        } finally {
          await restarted.db.closePersistence()
        }
      } finally {
        response.resolve(oldPage)
        await engine.stop()
        await context.db.closePersistence()
      }
    },
  )

  it("preserves authorized rejoined metadata while rejecting the old chat page and old membership removal", async () => {
    const context = await fixture()
    const { engine, client } = await openEngine(context)
    const requested = deferred<void>()
    const response = deferred<RpcResult["result"]>()
    const oldPage = updatesPage([oldMessage()], snapshot())
    let oldChatRequested = false
    client.otherUpdates = (input) => {
      if (!oldChatRequested && input.getUpdates.bucket?.type.oneofKind === "chat") {
        oldChatRequested = true
        requested.resolve()
        return response.promise
      }
      return emptyPage(input)
    }
    try {
      await engine.processPush([catchupHint("chat")])
      await requested.promise
      await replayThroughEngine(
        context,
        engine,
        client,
        [removed(), joined(2, 2_000n, "Rejoined Space")],
        snapshot(true),
      )
      const assertRejoined = (db: Db) => {
        expect(db.get(db.ref(DbObjectKind.Space, targetSpaceId))?.name).toBe("Rejoined Space")
        expect(db.get(db.ref(DbObjectKind.Chat, chatId(801)))?.title).toBe("Rejoined chat")
        expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))).toBeDefined()
        expect(db.get(db.ref(DbObjectKind.Message, messageKey(chatId(801), messageId(500))))).toBeUndefined()
        expect(db.get(db.ref(DbObjectKind.MessageDraft, draftKey))?.text).toBe("unsent local draft")
      }
      assertRejoined(context.db)
      response.resolve(oldPage)
      await engine.idle()
      assertRejoined(context.db)
      await engine.processPush([removed({ seq: 0, memberId: 1_000n })])
      await engine.idle()
      assertRejoined(context.db)
      expect((await context.storage.getBucketState({ kind: "user" })).seq).toBe(2)
      await engine.stop()
      await context.db.closePersistence()
      const restarted = await reopen(context.namespace)
      try {
        await restarted.db.hydrateKinds([DbObjectKind.Message])
        assertRejoined(restarted.db)
        expect(
          restarted.db.get(restarted.db.ref(DbObjectKind.Message, messageKey(chatId(801), messageId(1)))),
        ).toBeUndefined()
      } finally {
        await restarted.db.closePersistence()
      }
    } finally {
      response.resolve(oldPage)
      await engine.stop()
      await context.db.closePersistence()
    }
  })

  it.each(["getChat", "getChatHistory"] as const)(
    "rejects inherited child %s repair after same-page Space removal and rejoin restores the child",
    async (stage) => {
      const context = await fixture()
      const { engine, client } = await openEngine(context)
      const requested = deferred<void>()
      const response = deferred<RpcResult["result"]>()
      const peer = { type: { oneofKind: "chat" as const, chat: { chatId: 803n } } }
      const oldChat = { id: 803n, title: "Old inherited child", parentChatId: 801n, peerId: peer }
      const oldDialog = { chatId: 803n, peer, open: true }
      const oldMessage = {
        id: 500n,
        chatId: 803n,
        fromId: 7n,
        out: false,
        date: 100n,
        message: "Old child anchor",
        peerId: peer,
      }
      const oldChatResult: RpcResult["result"] = {
        oneofKind: "getChat",
        getChat: { chat: oldChat, dialog: oldDialog, anchorMessage: oldMessage, messages: [], pinnedMessageIds: [] },
      }
      const oldHistoryResult: RpcResult["result"] = {
        oneofKind: "getChatHistory",
        getChatHistory: { messages: [{ ...oldMessage, id: 501n, message: "Old child history" }] },
      }
      let firstChildRequest = true
      client.otherUpdates = (input) => {
        if (firstChildRequest && input.getUpdates.bucket?.type.oneofKind === "chat") {
          firstChildRequest = false
          return {
            oneofKind: "getUpdates",
            getUpdates: {
              seq: 500n,
              date: 100n,
              final: true,
              updates: [],
              skippedSequences: [],
              resultType: GetUpdatesResult_ResultType.TOO_LONG,
            },
          }
        }
        return emptyPage(input)
      }
      client.chatSnapshot = () => {
        if (stage === "getChat") {
          requested.resolve()
          return response.promise
        }
        return oldChatResult
      }
      client.chatHistory = () => {
        requested.resolve()
        return response.promise
      }
      const release = () => response.resolve(stage === "getChat" ? oldChatResult : oldHistoryResult)
      try {
        expect(context.db.get(context.db.ref(DbObjectKind.Chat, chatId(803)))?.spaceId).toBeUndefined()
        await engine.processPush([
          wireUpdate(
            Update.create({
              update: {
                oneofKind: "chatHasNewUpdates",
                chatHasNewUpdates: { chatId: 803n, peerId: peer, updateSeq: 500 },
              },
            }),
          ),
        ])
        await requested.promise
        const restoreChild = wireUpdate(
          Update.create({
            seq: 3,
            date: 103n,
            update: {
              oneofKind: "chatOpen",
              chatOpen: { chat: { ...oldChat, title: "Rejoined inherited child" }, dialog: oldDialog },
            },
          }),
        )
        await replayThroughEngine(
          context,
          engine,
          client,
          [removed(), joined(2, 2_000n, "Rejoined Space"), restoreChild],
          snapshot(true),
        )
        const assertRejoinedChild = (db: Db) => {
          expect(db.get(db.ref(DbObjectKind.Space, targetSpaceId))?.name).toBe("Rejoined Space")
          expect(db.get(db.ref(DbObjectKind.Chat, chatId(803)))).toMatchObject({
            title: "Rejoined inherited child",
            parentChatId: chatId(801),
          })
          expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-803)))).toBeDefined()
          for (const id of [messageId(1), messageId(500), messageId(501)]) {
            expect(db.get(db.ref(DbObjectKind.Message, messageKey(chatId(803), id)))).toBeUndefined()
          }
        }
        assertRejoinedChild(context.db)
        release()
        await engine.idle()
        assertRejoinedChild(context.db)
        expect(
          (
            await context.storage.getBucketState({
              kind: "chat",
              peer,
            })
          ).seq,
        ).toBe(0)
        expect((await context.storage.getBucketState({ kind: "user" })).seq).toBe(3)
        await engine.stop()
        await context.db.closePersistence()
        const restarted = await reopen(context.namespace)
        try {
          await restarted.db.hydrateKinds([DbObjectKind.Message])
          assertRejoinedChild(restarted.db)
        } finally {
          await restarted.db.closePersistence()
        }
      } finally {
        release()
        await engine.stop()
        await context.db.closePersistence()
      }
    },
  )

  it("keeps the original account actor when shared authentication changes and refuses a different-account restart", async () => {
    const context = await fixture()
    const sharedAuthStore = new AuthStore()
    const transport = new MockTransport()
    const client = new RealtimeClient({
      auth: sharedAuthStore,
      db: context.db,
      transport,
      url: "ws://example.test",
      sync: false,
    })
    const connected = deferred<void>()
    const unsubscribeState = client.onConnectionState((state) => {
      if (state === "connected") connected.resolve()
    })
    const applied = deferred<void>()
    const unsubscribeChanges = context.db.subscribeToResidentChanges((batch) => {
      if (
        batch.changes.some(
          (change) => change.kind === DbObjectKind.Space || change.kind === DbObjectKind.DeferredUpdate,
        )
      ) {
        applied.resolve()
      }
    })
    try {
      await client.startSession({ token: "test-user7-token", userId: currentUserId })
      await transport.connect()
      await transport.emitMessage(
        ServerProtocolMessage.create({
          id: 1n,
          body: { oneofKind: "connectionOpen", connectionOpen: {} },
        }),
      )
      await connected.promise
      await expect(client.startSession({ token: "test-user8-token", userId: userId(8) })).rejects.toThrow(
        "Inline realtime belongs to another account",
      )
      expect(sharedAuthStore.getState().currentUserId).toBe(currentUserId)
      expect(client.connectionState).toBe("connected")
      await sharedAuthStore.login({ token: "test-user8-token", userId: userId(8) })
      expect(sharedAuthStore.getState().currentUserId).toBe(userId(8))
      const frame = ServerProtocolMessage.create({
        id: 2n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: { updates: [removed({ seq: 0, user: 8n, memberId: 1_000n })] },
            },
          },
        },
      })
      await transport.emitMessage(ServerProtocolMessage.fromBinary(ServerProtocolMessage.toBinary(frame)))
      await applied.promise
      expect(context.db.get(context.db.ref(DbObjectKind.Space, targetSpaceId))?.name).toBe("Private Space")
      for (const id of removedChats) {
        expect(context.db.get(context.db.ref(DbObjectKind.Chat, id))).toBeDefined()
        expect(context.db.get(context.db.ref(DbObjectKind.Dialog, dialogId(-BigInt(id))))).toBeDefined()
      }
      const retained = context.db
        .queryCollection(DbQueryPlanType.Objects, DbObjectKind.DeferredUpdate)
        .find((update) => update.updateType === "spaceMemberDelete")
      expect(retained).toBeDefined()
      expect(Update.fromBinary(retained!.payload).update).toMatchObject({
        oneofKind: "spaceMemberDelete",
        spaceMemberDelete: { spaceId: 17n, userId: 8n },
      })
      await client.stop()
      await expect(client.start()).rejects.toThrow("Inline realtime belongs to another account")
      expect(client.connectionState).toBe("idle")
      expect(transport.state).toBe("idle")
      expect(
        await context.store.collection(DbObjectKind.Message).get(messageKey(chatId(801), messageId(1))),
      ).toBeDefined()
    } finally {
      unsubscribeState()
      unsubscribeChanges()
      await client.stop()
      await context.db.closePersistence()
    }
  })
})
