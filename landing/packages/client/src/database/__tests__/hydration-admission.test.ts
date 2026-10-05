import { ClientMessage, Method, ServerProtocolMessage, Update } from "@inline-chat/protocol/core"
import { chatId, messageId, userId } from "@inline/ids"
import { IDBFactory, IDBKeyRange } from "fake-indexeddb"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { AuthStore } from "../../auth"
import { RealtimeClient } from "../../realtime/realtime"
import { sendMessage } from "../../realtime/transactions/send-message"
import { MockTransport } from "../../realtime/transport/mock-transport"
import { Db } from "../index"
import {
  DbObjectKind,
  MessageSendingStatus,
  messageKey,
  type DbModel,
  type DeferredUpdate,
  type Message,
} from "../models"
import { createIndexedDbPersistenceStore } from "../storage"
import { DbQueryPlanType } from "../types"

const targetChatId = chatId(10)
const peer = {
  type: { oneofKind: "chat" as const, chat: { chatId: 10n } },
}

const deferred = <T>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((settle) => {
    resolve = settle
  })
  return { promise, resolve }
}

const delayRead = <Args extends unknown[], Result>(read: (...args: Args) => Promise<Result>) => {
  const captured = deferred<Result>()
  const released = deferred<void>()
  return {
    captured: captured.promise,
    release: () => released.resolve(),
    read: async (...args: Args) => {
      const result = await read(...args)
      captured.resolve(result)
      await released.promise
      return result
    },
  }
}

const message = (id = 21, rawChatId = 10): Message => ({
  kind: DbObjectKind.Message,
  id: messageKey(chatId(rawChatId), messageId(id)),
  messageId: messageId(id),
  chatId: chatId(rawChatId),
  fromId: userId(7),
  date: 1_000,
  message: "Persisted before mutation",
})

const fixture = async (objects: DbModel[] = []) => {
  const namespace = `hydration-admission-${crypto.randomUUID()}`
  const store = createIndexedDbPersistenceStore(namespace)
  if (!store) throw new Error("IndexedDB persistence unavailable")
  await store.open()
  await store.write(objects.map((object) => ({ type: "put", object })))
  const db = new Db({ autoHydrate: false, persistenceStore: store })
  return { namespace, store, db }
}

const reopen = async (namespace: string, kinds: DbObjectKind[]) => {
  const db = new Db({ autoHydrate: false, storageNamespace: namespace })
  await db.hydrateKinds(kinds)
  return db
}

class BinaryMockTransport extends MockTransport {
  readonly sendRequested = deferred<ClientMessage>()

  override async send(message: ClientMessage) {
    const decoded = ClientMessage.fromBinary(ClientMessage.toBinary(message))
    await super.send(decoded)
    if (decoded.body.oneofKind === "rpcCall" && decoded.body.rpcCall.method === Method.SEND_MESSAGE) {
      this.sendRequested.resolve(decoded)
    }
  }

  emitWire(message: ServerProtocolMessage) {
    return this.emitMessage(ServerProtocolMessage.fromBinary(ServerProtocolMessage.toBinary(message)))
  }
}

describe("database hydration admission", () => {
  beforeEach(() => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
  })

  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("retains a canonical live message committed after a latest-window snapshot was captured", async () => {
    const stored = message(21)
    const live: Message = {
      ...message(22),
      date: 1_001,
      message: "New live message",
      status: MessageSendingStatus.Sent,
    }
    const context = await fixture([
      stored,
      {
        kind: DbObjectKind.Chat,
        id: targetChatId,
        lastMsgId: stored.messageId,
        date: stored.date,
      },
    ])
    await context.db.hydrateKinds([DbObjectKind.Chat])
    context.db.activateResidentMessageWindow(targetChatId)
    const messages = context.store.collection(DbObjectKind.Message)
    if (!messages.getMessageWindowByChatId) throw new Error("Indexed message window unavailable")
    const blocked = delayRead(messages.getMessageWindowByChatId.bind(messages))
    vi.spyOn(messages, "getMessageWindowByChatId").mockImplementation(blocked.read)
    const hydration = context.db.hydrateMessageWindow(targetChatId, { limit: 10 })
    try {
      expect(await blocked.captured).toEqual([stored])
      let included = false
      await context.db.commit(() => {
        context.db.insert(live)
        context.db.update({
          ...context.db.get(context.db.ref(DbObjectKind.Chat, targetChatId))!,
          lastMsgId: live.messageId,
          date: live.date,
        })
        included = context.db.includeMessageInActiveLatestWindow(live)
      })
      expect(included).toBe(true)
      blocked.release()
      await hydration
      expect(context.db.fullChatWindows.keys(targetChatId)).toEqual([stored.id, live.id])
      expect(context.db.get(context.db.ref(DbObjectKind.Message, live.id))).toEqual(live)
      expect(context.db.get(context.db.ref(DbObjectKind.Chat, targetChatId))?.lastMsgId).toBe(live.messageId)
    } finally {
      blocked.release()
      await hydration
      await context.db.closePersistence()
    }
  })

  it.each(["delete", "clear"] as const)(
    "does not admit an around-message snapshot when %s occurs during deferred preparation",
    async (mutation) => {
      const row = message()
      const context = await fixture([row])
      context.db.activateResidentMessageWindow(targetChatId)
      const messages = context.store.collection(DbObjectKind.Message)
      const aroundRead = vi.spyOn(messages, "getMessageWindowAroundMessageId")
      const deferredUpdates = context.store.collection(DbObjectKind.DeferredUpdate)
      if (!deferredUpdates.getDeferredUpdatesByTargetKeys) throw new Error("Indexed deferred reads unavailable")
      const blocked = delayRead(deferredUpdates.getDeferredUpdatesByTargetKeys.bind(deferredUpdates))
      vi.spyOn(deferredUpdates, "getDeferredUpdatesByTargetKeys").mockImplementation(blocked.read)
      const hydration = context.db.loadLocalWindowAroundMessageDetails(targetChatId, {
        messageId: row.messageId,
        beforeLimit: 0,
        afterLimit: 0,
      })
      try {
        await blocked.captured
        expect(aroundRead).toHaveBeenCalledOnce()
        await context.db.commit(() => {
          if (mutation === "delete") {
            context.db.delete(context.db.ref(DbObjectKind.Message, row.id))
          } else {
            context.db.clearMessagesForChat(targetChatId)
          }
        })
        blocked.release()
        expect(await hydration).toEqual({ found: false, messageKeys: [] })
        expect(context.db.get(context.db.ref(DbObjectKind.Message, row.id))).toBeUndefined()
        expect(context.db.fullChatWindows.keys(targetChatId)).toEqual([])
        expect(await messages.get(row.id)).toBeUndefined()
      } finally {
        blocked.release()
        await hydration
        await context.db.closePersistence()
      }
    },
  )

  it("does not restore a deleted deferred row from a delayed indexed target read", async () => {
    const target = message()
    const update = Update.create({
      seq: 1,
      date: 1_001n,
      update: {
        oneofKind: "updateReaction",
        updateReaction: {
          reaction: {
            emoji: "🔥",
            userId: 7n,
            messageId: 21n,
            chatId: 10n,
            date: 1_001n,
          },
        },
      },
    })
    const row: DeferredUpdate = {
      kind: DbObjectKind.DeferredUpdate,
      id: "pending-reaction",
      bucketId: "chat:chat:10",
      seq: 1,
      date: 1_001,
      payloadType: "Update",
      updateType: "updateReaction",
      targetKey: target.id,
      payload: Update.toBinary(update),
    }
    const context = await fixture([row])
    const deferredUpdates = context.store.collection(DbObjectKind.DeferredUpdate)
    if (!deferredUpdates.getDeferredUpdatesByTargetKeys) throw new Error("Indexed deferred reads unavailable")
    const blocked = delayRead(deferredUpdates.getDeferredUpdatesByTargetKeys.bind(deferredUpdates))
    vi.spyOn(deferredUpdates, "getDeferredUpdatesByTargetKeys").mockImplementation(blocked.read)
    const hydration = context.db.hydrateDeferredUpdatesForMessageKeys([target.id])
    try {
      expect(await blocked.captured).toEqual([row])
      await context.db.commit(() => context.db.delete(context.db.ref(DbObjectKind.DeferredUpdate, row.id)))
      blocked.release()
      await hydration
      expect(context.db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.DeferredUpdate)).toEqual([])
      expect(await deferredUpdates.get(row.id)).toBeUndefined()
      const restarted = await reopen(context.namespace, [DbObjectKind.DeferredUpdate])
      try {
        expect(restarted.queryCollection(DbQueryPlanType.Objects, DbObjectKind.DeferredUpdate)).toEqual([])
      } finally {
        await restarted.closePersistence()
      }
    } finally {
      blocked.release()
      await hydration
      await context.db.closePersistence()
    }
  })

  it("does not resurrect a persisted temporary send after its ACK mapping and outbox removal", async () => {
    const context = await fixture()
    const messages = context.store.collection(DbObjectKind.Message)
    const windowRead = messages.getMessageWindowByChatId
    if (!windowRead) throw new Error("Indexed message window unavailable")
    const blocked = delayRead(windowRead.bind(messages))
    vi.spyOn(messages, "getMessageWindowByChatId").mockImplementation(blocked.read)
    const transport = new BinaryMockTransport()
    const client = new RealtimeClient({
      auth: new AuthStore(),
      db: context.db,
      transport,
      url: "ws://example.test",
      sync: false,
    })
    const temporaryId = messageId(-1)
    const temporaryKey = messageKey(targetChatId, temporaryId)
    const canonicalKey = messageKey(targetChatId, messageId(500))
    const connected = deferred<void>()
    const unsubscribe = client.onConnectionState((state) => {
      if (state === "connected") connected.resolve()
    })
    try {
      await context.db.commit(() =>
        context.db.insert({
          kind: DbObjectKind.Chat,
          id: targetChatId,
          title: "Thread",
        }),
      )
      context.db.activateResidentMessageWindow(targetChatId)
      await client.startSession({ token: "test-token", userId: userId(7) })
      await transport.connect()
      await transport.emitWire(
        ServerProtocolMessage.create({
          id: 1n,
          body: { oneofKind: "connectionOpen", connectionOpen: {} },
        }),
      )
      await connected.promise

      const sent = client.mutate(
        sendMessage({
          chatId: targetChatId,
          peerId: peer,
          text: "Sent once",
          randomId: 42n,
          temporaryMessageId: temporaryId,
          temporarySendDate: 1_000,
        }),
      )
      void sent.catch(() => undefined)
      const [request, captured] = await Promise.all([transport.sendRequested.promise, blocked.captured])
      expect(captured).toMatchObject([
        {
          id: temporaryKey,
          status: MessageSendingStatus.Sending,
        },
      ])
      expect(context.db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.PendingTransaction)).toHaveLength(1)

      await transport.emitWire(
        ServerProtocolMessage.create({
          id: 2n,
          body: { oneofKind: "ack", ack: { msgId: request.id } },
        }),
      )
      await transport.emitWire(
        ServerProtocolMessage.create({
          id: 3n,
          body: {
            oneofKind: "rpcResult",
            rpcResult: {
              reqMsgId: request.id,
              result: {
                oneofKind: "sendMessage",
                sendMessage: {
                  updates: [
                    Update.create({
                      update: {
                        oneofKind: "updateMessageId",
                        updateMessageId: { messageId: 500n, randomId: 42n },
                      },
                    }),
                  ],
                },
              },
            },
          },
        }),
      )
      await sent
      expect(context.db.get(context.db.ref(DbObjectKind.Message, temporaryKey))).toBeUndefined()
      expect(context.db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.PendingTransaction)).toEqual([])
      blocked.release()
      await client.stop()

      expect(context.db.get(context.db.ref(DbObjectKind.Message, temporaryKey))).toBeUndefined()
      expect(context.db.fullChatWindows.keys(targetChatId)).not.toContain(temporaryKey)
      expect(context.db.fullChatWindows.keys(targetChatId)).toContain(canonicalKey)
      expect(context.db.get(context.db.ref(DbObjectKind.Message, canonicalKey))).toMatchObject({
        message: "Sent once",
        status: MessageSendingStatus.Sent,
      })
      expect(await messages.get(temporaryKey)).toBeUndefined()
      const restarted = await reopen(context.namespace, [DbObjectKind.Message, DbObjectKind.PendingTransaction])
      try {
        expect(restarted.get(restarted.ref(DbObjectKind.Message, temporaryKey))).toBeUndefined()
        expect(restarted.get(restarted.ref(DbObjectKind.Message, canonicalKey))?.status).toBe(MessageSendingStatus.Sent)
        expect(restarted.queryCollection(DbQueryPlanType.Objects, DbObjectKind.PendingTransaction)).toEqual([])
      } finally {
        await restarted.closePersistence()
      }
    } finally {
      unsubscribe()
      blocked.release()
      await client.stop()
      await context.db.closePersistence()
    }
  })

  it("does not insert a delayed exact-object read after the object was deleted", async () => {
    const row = message()
    const context = await fixture([row])
    const messages = context.store.collection(DbObjectKind.Message)
    if (!messages.getMany) throw new Error("Exact object reads unavailable")
    const blocked = delayRead(messages.getMany.bind(messages))
    vi.spyOn(messages, "getMany").mockImplementation(blocked.read)
    const hydration = context.db.hydrateObjects(DbObjectKind.Message, [row.id])
    try {
      expect(await blocked.captured).toEqual([row])
      await context.db.commit(() => context.db.delete(context.db.ref(DbObjectKind.Message, row.id)))
      blocked.release()
      await hydration
      expect(context.db.get(context.db.ref(DbObjectKind.Message, row.id))).toBeUndefined()
      expect(await messages.get(row.id)).toBeUndefined()
    } finally {
      blocked.release()
      await hydration
      await context.db.closePersistence()
    }
  })

  it("does not admit an exact-object snapshot older than a persisted nonresident edit", async () => {
    const row = message()
    const context = await fixture([row])
    const messages = context.store.collection(DbObjectKind.Message)
    if (!messages.getMany) throw new Error("Exact object reads unavailable")
    const blocked = delayRead(messages.getMany.bind(messages))
    const delayedRead = vi.spyOn(messages, "getMany").mockImplementation(blocked.read)
    const hydration = context.db.hydrateObjects(DbObjectKind.Message, [row.id])
    try {
      await blocked.captured
      await context.db.commit(() =>
        context.db.storeNonResidentObject({
          ...row,
          message: "Newer persisted edit",
          editDate: 1_001,
        }),
      )
      blocked.release()
      await hydration
      expect(context.db.get(context.db.ref(DbObjectKind.Message, row.id))?.message).not.toBe(row.message)
      delayedRead.mockRestore()
      await context.db.hydrateObjects(DbObjectKind.Message, [row.id])
      expect(context.db.get(context.db.ref(DbObjectKind.Message, row.id))?.message).toBe("Newer persisted edit")
    } finally {
      blocked.release()
      await hydration
      await context.db.closePersistence()
    }
  })

  it("does not restore a deleted Chat from delayed full cache hydration", async () => {
    const row: DbModel = { kind: DbObjectKind.Chat, id: targetChatId, title: "Deleted thread" }
    const context = await fixture([row])
    const chats = context.store.collection(DbObjectKind.Chat)
    const blocked = delayRead(chats.getAll.bind(chats))
    vi.spyOn(chats, "getAll").mockImplementation(blocked.read)
    const hydration = context.db.hydrate()
    try {
      expect(await blocked.captured).toEqual([row])
      await context.db.commit(() => context.db.delete(context.db.ref(DbObjectKind.Chat, targetChatId)))
      blocked.release()
      await hydration
      expect(context.db.get(context.db.ref(DbObjectKind.Chat, targetChatId))).toBeUndefined()
      expect(await chats.get(targetChatId)).toBeUndefined()
    } finally {
      blocked.release()
      await hydration
      await context.db.closePersistence()
    }
  })

  it("does not restore cleared unloaded history during full Message-kind hydration", async () => {
    const removed = message(21, 10)
    const retained = message(22, 20)
    const context = await fixture([removed, retained])
    const messages = context.store.collection(DbObjectKind.Message)
    const blocked = delayRead(messages.getAll.bind(messages))
    vi.spyOn(messages, "getAll").mockImplementation(blocked.read)
    const hydration = context.db.hydrateKinds([DbObjectKind.Message])
    try {
      expect(await blocked.captured).toHaveLength(2)
      await context.db.commit(() => context.db.clearMessagesForChat(targetChatId))
      blocked.release()
      await hydration
      expect(context.db.get(context.db.ref(DbObjectKind.Message, removed.id))).toBeUndefined()
      expect(context.db.get(context.db.ref(DbObjectKind.Message, retained.id))).toEqual(retained)
      const restarted = await reopen(context.namespace, [DbObjectKind.Message])
      try {
        expect(restarted.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message)).toEqual([retained])
      } finally {
        await restarted.closePersistence()
      }
    } finally {
      blocked.release()
      await hydration
      await context.db.closePersistence()
    }
  })

  it("waits for a pending delete commit before reading a local message window", async () => {
    const row = message()
    const context = await fixture([row])
    await context.db.hydrateObjects(DbObjectKind.Message, [row.id])
    const messages = context.store.collection(DbObjectKind.Message)
    if (!messages.getMessageWindowByChatId) throw new Error("Indexed message window unavailable")
    const windowRead = vi.spyOn(messages, "getMessageWindowByChatId")
    const writeStarted = deferred<void>()
    const releaseWrite = deferred<void>()
    const write = context.store.write.bind(context.store)
    vi.spyOn(context.store, "write").mockImplementation(async (operations) => {
      if (
        operations.some(
          (operation) =>
            operation.type === "delete" && operation.kind === DbObjectKind.Message && operation.id === row.id,
        )
      ) {
        writeStarted.resolve()
        await releaseWrite.promise
      }
      await write(operations)
    })
    const deletion = context.db.commit(() => context.db.delete(context.db.ref(DbObjectKind.Message, row.id)))
    let hydration: Promise<number> | undefined
    try {
      await writeStarted.promise
      expect(context.db.get(context.db.ref(DbObjectKind.Message, row.id))).toBeUndefined()
      hydration = context.db.hydrateMessageWindow(targetChatId, { limit: 10 })
      let resolved = false
      void hydration.then(() => {
        resolved = true
      })
      // An independent adapter read lets scheduled IndexedDB work progress
      // while the delete's account-store commit remains deliberately blocked.
      await context.store.collection(DbObjectKind.User).get(userId(7))
      expect(windowRead).not.toHaveBeenCalled()
      expect(resolved).toBe(false)
      releaseWrite.resolve()
      await deletion
      await hydration
      expect(context.db.get(context.db.ref(DbObjectKind.Message, row.id))).toBeUndefined()
      expect(await messages.get(row.id)).toBeUndefined()
    } finally {
      releaseWrite.resolve()
      await deletion
      await hydration
      await context.db.closePersistence()
    }
  })
})
