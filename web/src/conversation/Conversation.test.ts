import "fake-indexeddb/auto"
import {
  AuthStore,
  Db,
  DbObjectKind,
  DbQueryPlanType,
  MessageSendingStatus,
  RealtimeClient,
  applyUpdates,
  createIndexedDbPersistenceStore,
  messageDraftKey,
  messageKey,
  sendMessage,
  type Chat,
  type Message,
  type RealtimeService,
  type Transaction,
} from "@inline/client/core"
import {
  GetChatHistoryMode,
  Message as ProtocolMessageCodec,
  Method,
  RpcError_Code,
  ServerProtocolMessage,
  Update,
  type Message as ProtocolMessage,
  type RpcResult,
} from "@inline-chat/protocol/core"
import { chatId, messageId, userId, type ChatID, type MessageID } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import { Conversation } from "./Conversation"
import { MockTransport } from "../../../landing/packages/client/src/realtime/transport/mock-transport"
import { DbSyncStorage } from "../../../landing/packages/client/src/realtime/sync/db-sync-storage"
import { upsertChat } from "../../../landing/packages/client/src/realtime/transactions/mappers"

const targetChat = chatId(10)
const chat: Chat = { kind: DbObjectKind.Chat, id: targetChat, title: "Team" }
const draftId = messageDraftKey({ peerKind: "chat", peerThreadId: targetChat })
const protocolMessage = (id: number): ProtocolMessage => ({
  id: BigInt(id),
  fromId: 8n,
  chatId: 10n,
  date: BigInt(id),
  message: `Message ${id}`,
  out: false,
})
const cachedMessage = (id: number): Message => ({
  kind: DbObjectKind.Message,
  id: messageKey(targetChat, messageId(id)),
  messageId: messageId(id),
  fromId: userId(8),
  chatId: targetChat,
  date: id,
  message: `Message ${id}`,
})
const ids = (first: number, last: number) =>
  Array.from({ length: last - first + 1 }, (_, index) => first + index)
const deferred = <T>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((r) => {
    resolve = r
  })
  return { promise, resolve }
}

const fixture = async (seed: Message[] = []) => {
  const store = createIndexedDbPersistenceStore(`conversation-test-${crypto.randomUUID()}`)!
  const db = new Db({ autoHydrate: false, persistenceStore: store })
  const auth = new AuthStore()
  await auth.ready
  await auth.login({ token: "conversation-test", userId: userId(7) })
  await db.commit(() => {
    db.insert(chat)
    seed.forEach((message) => db.insert(message))
  })
  db.releaseResidentMessageWindow(targetChat)
  let history = async (_transaction: Transaction): Promise<(number | ProtocolMessage)[]> => []
  const query = vi.fn(async (transaction: Transaction) => {
    transaction.beforeExecute?.(db)
    const messages = await history(transaction)
    const result: RpcResult["result"] = {
      oneofKind: "getChatHistory",
      getChatHistory: {
        messages: messages.map((message) =>
          typeof message === "number" ? protocolMessage(message) : message,
        ),
      },
    }
    await db.commit(() => {
      transaction.apply(result, db)
    })
    transaction.afterCommit?.(result, db)
    return result
  })
  const mutateAccepted = vi.fn(async (transaction: Transaction) => {
    await db.commit(() => {
      transaction.optimistic?.(db, auth)
    })
  })
  const resendMessage = vi.fn(
    async (_chatId: ChatID, _messageId: MessageID): Promise<RpcResult["result"] | undefined> =>
      undefined,
  )
  const realtime = { query, mutateAccepted, resendMessage } as unknown as RealtimeService
  const conversation = new Conversation(db, realtime, chat)
  return {
    db,
    store,
    auth,
    query,
    mutateAccepted,
    resendMessage,
    realtime,
    conversation,
    setHistory: (handler: typeof history) => {
      history = handler
    },
  }
}

const openCertified = async (conversation: Conversation) => {
  await conversation.start()
  await vi.waitFor(() => expect(conversation.getSnapshot().refreshingLatest).toBe(false), {
    timeout: 5000,
  })
}

describe("Conversation", () => {
  it("loads a cached window and persisted draft before latest network history", async () => {
    const f = await fixture([cachedMessage(5)])
    await f.db.commit(() => {
      f.db.replace({
        kind: DbObjectKind.MessageDraft,
        id: draftId,
        peerKind: "chat",
        peerThreadId: targetChat,
        text: "Saved",
        revision: 1,
        updatedAt: 1,
      })
    })
    const response = deferred<number[]>()
    f.setHistory(() => response.promise)
    await f.conversation.start()
    expect(f.query).toHaveBeenCalledTimes(1)
    expect(f.conversation.getSnapshot().loading).toBe(false)
    expect(f.conversation.getSnapshot().refreshingLatest).toBe(true)
    expect(f.conversation.getSnapshot().messages.map((message) => message.messageId)).toEqual([
      messageId(5),
    ])
    expect(f.conversation.getSnapshot().draft).toBe("Saved")
    expect(f.conversation.getSnapshot().hasOlder).toBe(false)
    expect(f.conversation.getSnapshot().historyCertified).toBe(false)
    response.resolve([9, 10])
    await vi.waitFor(() => expect(f.conversation.getSnapshot().refreshingLatest).toBe(false))
    expect(f.conversation.getSnapshot().messages.map((message) => message.messageId)).toEqual([
      messageId(9),
      messageId(10),
    ])
    expect(f.conversation.getSnapshot().historyCertified, f.conversation.getSnapshot().error).toBe(
      true,
    )
    f.conversation.stop()
    await f.db.closePersistence()
  })

  it("certifies older history with a server lookahead and uses the retained server cursor", async () => {
    const f = await fixture()
    f.setHistory(async (transaction) => {
      const context = transaction.context as {
        mode: GetChatHistoryMode
        beforeId?: string
        limit?: number
      }
      expect(context.limit).toBe(61)
      if (context.mode === GetChatHistoryMode.HISTORY_MODE_LATEST) return ids(40, 100)
      expect(context.beforeId).toBe(messageId(41))
      return ids(1, 40)
    })
    await openCertified(f.conversation)
    expect(f.conversation.getSnapshot().messages).toHaveLength(60)
    expect(f.conversation.getSnapshot().messages[0]?.messageId).toBe(messageId(41))
    expect(f.conversation.getSnapshot().hasOlder).toBe(true)
    await f.conversation.loadOlder()
    expect(f.conversation.getSnapshot().messages).toHaveLength(100)
    expect(f.conversation.getSnapshot().hasOlder).toBe(false)
    expect(f.conversation.getSnapshot().messages[0]?.messageId).toBe(messageId(1))
    f.conversation.stop()
    await f.db.closePersistence()
  })

  it("rejects cached preparation failures before a route can construct rows", async () => {
    const f = await fixture([cachedMessage(5)])
    vi.spyOn(f.db, "hydrateObjects").mockRejectedValueOnce(new Error("draft storage unavailable"))
    await expect(f.conversation.start()).rejects.toThrow("draft storage unavailable")
    expect(f.query).not.toHaveBeenCalled()
    expect(f.conversation.getSnapshot().error).toContain("draft storage unavailable")
    f.conversation.stop()
    await f.db.closePersistence()
  })

  it("fences late cached hydration after the same peer is prepared by a newer route", async () => {
    const f = await fixture([cachedMessage(5)])
    const cacheRead = deferred<Message[]>()
    const collection = f.store.collection(DbObjectKind.Message)
    const reading = vi
      .spyOn(collection, "getMessageWindowByChatId")
      .mockImplementationOnce(() => cacheRead.promise)
    const oldOpening = f.conversation.start()
    await vi.waitFor(() => expect(reading).toHaveBeenCalledTimes(1))
    f.conversation.stop()
    f.setHistory(async () => [100])
    const current = new Conversation(f.db, f.realtime, chat)
    await openCertified(current)
    const currentSnapshot = current.getSnapshot()
    cacheRead.resolve([cachedMessage(5)])
    await oldOpening
    expect(current.getSnapshot()).toBe(currentSnapshot)
    expect(current.getSnapshot().messages.map((message) => message.messageId)).toEqual([
      messageId(100),
    ])
    expect(f.query).toHaveBeenCalledTimes(1)
    current.stop()
    await f.db.closePersistence()
  })

  it("bounds paginated windows to 200 rows and marks trimmed latest content", async () => {
    const f = await fixture()
    f.setHistory(async (transaction) => {
      const context = transaction.context as { beforeId?: string }
      const tail = context.beforeId == null ? 500 : Number(context.beforeId) - 1
      return ids(tail - 60, tail)
    })
    await openCertified(f.conversation)
    for (let page = 0; page < 4; page++) await f.conversation.loadOlder()
    const snapshot = f.conversation.getSnapshot()
    expect(snapshot.messages).toHaveLength(200)
    expect(snapshot.messages[0]?.messageId).toBe(messageId(201))
    expect(snapshot.messages.at(-1)?.messageId).toBe(messageId(400))
    expect(snapshot.atLatest).toBe(false)
    expect(snapshot.historyCertified).toBe(false)
    expect(f.db.fullChatWindows.keys(targetChat)).toHaveLength(200)
    f.conversation.stop()
    await f.db.closePersistence()
  })

  it("fences a response from a disposed conversation when the same chat reopens", async () => {
    const f = await fixture()
    const late = deferred<number[]>()
    f.setHistory(() => late.promise)
    const first = f.conversation.start()
    await vi.waitFor(() => expect(f.query).toHaveBeenCalledTimes(1))
    f.conversation.stop()
    const stopped = f.conversation.getSnapshot()
    const currentResponse = deferred<number[]>()
    f.setHistory(() => currentResponse.promise)
    const reopened = new Conversation(f.db, f.realtime, chat)
    await reopened.start()
    expect(reopened.getSnapshot().historyCertified).toBe(false)
    late.resolve([5])
    await first
    await f.query.mock.results[0]!.value
    expect(f.conversation.getSnapshot()).toBe(stopped)
    expect(reopened.getSnapshot().historyCertified).toBe(false)
    expect(reopened.getSnapshot().messages).toHaveLength(0)
    currentResponse.resolve([100])
    await vi.waitFor(() => expect(reopened.getSnapshot().refreshingLatest).toBe(false))
    expect(reopened.getSnapshot().messages.map((message) => message.messageId)).toEqual([
      messageId(100),
    ])
    expect(reopened.getSnapshot().historyCertified).toBe(true)
    reopened.stop()
    await f.db.closePersistence()
  })

  it("keeps the snapshot stable while idle and draft input responsive before storage acceptance", async () => {
    const f = await fixture()
    await openCertified(f.conversation)
    expect(f.conversation.getSnapshot()).toBe(f.conversation.getSnapshot())
    const writing = f.conversation.setDraft("Typing")
    expect(f.conversation.getSnapshot().draft).toBe("Typing")
    await writing
    expect(f.db.get(f.db.ref(DbObjectKind.MessageDraft, draftId))?.text).toBe("Typing")
    f.conversation.stop()
    await f.db.closePersistence()
  })

  it("retires on committed chat deletion and rejects late history after the ID is recreated", async () => {
    const f = await fixture([cachedMessage(5)])
    const late = deferred<number[]>()
    f.setHistory(() => late.promise)
    await f.conversation.start()
    expect(f.conversation.getSnapshot().messages).toHaveLength(1)
    await f.db.commit(() => {
      f.db.delete(f.db.ref(DbObjectKind.Chat, targetChat))
      f.db.delete(f.db.ref(DbObjectKind.Message, cachedMessage(5).id))
    })
    expect(f.conversation.getSnapshot().unavailable).toBe(true)
    expect(f.conversation.getSnapshot().messages).toHaveLength(0)
    await f.db.commit(() => {
      f.db.insert(chat)
    })
    const retired = f.conversation.getSnapshot()
    late.resolve([100])
    await f.query.mock.results[0]!.value
    expect(f.db.get(f.db.ref(DbObjectKind.Message, cachedMessage(100).id))).toBeUndefined()
    expect(f.db.fullChatWindows.keys(targetChat)).toHaveLength(0)
    expect(f.conversation.getSnapshot()).toBe(retired)
    expect(f.conversation.getSnapshot().historyCertified).toBe(false)
    await f.db.closePersistence()
  })

  it("refreshes a startup page once for an ordinary user snapshot without an observed mapping and bounds repeated catchup", async () => {
    const f = await fixture([cachedMessage(5)])
    const syncStorage = new DbSyncStorage(f.db)
    const pages: Array<ReturnType<typeof deferred<number[]>>> = []
    f.setHistory(() => {
      const page = deferred<number[]>()
      pages.push(page)
      return page.promise
    })
    try {
      await f.conversation.start()
      const catchup = (seq: number) =>
        syncStorage.commitBucketState({ kind: "user" }, { seq, date: 200 + seq }, () => {
          upsertChat(f.db, { id: 10n, title: "Team" })
        })
      expect(await catchup(1)).toBe(true)
      expect(f.conversation.getSnapshot().error).toBeUndefined()
      expect(f.conversation.getSnapshot().historyCertified).toBe(false)
      await vi.waitFor(() => expect(pages).toHaveLength(2))

      // A second snapshot cannot grow an automatic fetch loop. Both original
      // responses remain inadmissible, including the replacement now fenced.
      expect(await catchup(2)).toBe(true)
      expect(f.conversation.getSnapshot().error).toContain("Retry latest history")
      expect(f.query).toHaveBeenCalledTimes(2)
      pages.forEach((page) => page.resolve([100]))
      await Promise.all(f.query.mock.results.map((request) => request.value))
      expect(f.db.get(f.db.ref(DbObjectKind.Message, cachedMessage(100).id))).toBeUndefined()
      expect(f.conversation.getSnapshot().historyCertified).toBe(false)
      expect(f.query).toHaveBeenCalledTimes(2)

      // Explicit Retry starts a new bounded lineage and can regain coverage.
      const retrying = f.conversation.retryError()
      await vi.waitFor(() => expect(pages).toHaveLength(3))
      expect(await catchup(3)).toBe(true)
      expect(f.conversation.getSnapshot().error).toBeUndefined()
      await vi.waitFor(() => expect(pages).toHaveLength(4))
      pages[2]!.resolve([101])
      await retrying
      expect(f.db.get(f.db.ref(DbObjectKind.Message, cachedMessage(101).id))).toBeUndefined()
      expect(f.conversation.getSnapshot().historyCertified).toBe(false)
      pages[3]!.resolve([102])
      await vi.waitFor(() => expect(f.conversation.getSnapshot().refreshingLatest).toBe(false))
      expect(f.conversation.getSnapshot().historyCertified).toBe(true)
      expect(f.conversation.getSnapshot().error).toBeUndefined()
      expect(f.conversation.getSnapshot().messages.map((message) => message.messageId)).toEqual([
        messageId(102),
      ])
    } finally {
      pages.forEach((page) => page.resolve([]))
      f.conversation.stop()
      await f.conversation.drain()
      await Promise.all(f.query.mock.results.map((request) => request.value))
      await f.db.closePersistence()
    }
  })

  it.each([false, true])(
    "fences coalesced access removal and regrant with cached inventory %s without closing the finally authorized pane",
    async (hasCachedMessages) => {
      const f = await fixture(hasCachedMessages ? [cachedMessage(5)] : [])
      const late = deferred<number[]>()
      const authorized = deferred<number[]>()
      let requests = 0
      f.setHistory(() => (++requests === 1 ? late.promise : authorized.promise))
      await f.conversation.start()
      await f.db.commit(() => {
        applyUpdates(f.db, [
          Update.create({
            update: { oneofKind: "userRemovedFromChat", userRemovedFromChat: { chatId: 10n } },
          }),
          Update.create({
            update: { oneofKind: "userAddedToChat", userAddedToChat: { chatId: 10n } },
          }),
        ])
        f.db.replace({ ...chat, title: "Rejoined" })
        f.db.replace({ kind: DbObjectKind.SyncBucketState, id: "user", seq: 2, date: 200 })
      })
      expect(f.conversation.getSnapshot().unavailable).toBe(false)
      expect(f.conversation.getSnapshot().historyCertified).toBe(false)
      if (hasCachedMessages)
        expect(f.conversation.getSnapshot().error).toContain("Retry latest history")
      else {
        // With no changed positive rows, the coalesced transition is still
        // fenced; only one fresh, currently authorized response may certify it.
        expect(f.conversation.getSnapshot().error).toBeUndefined()
        await vi.waitFor(() => expect(f.query).toHaveBeenCalledTimes(2))
      }
      await f.conversation.setDraft("Typing must not hide required history retry")
      if (hasCachedMessages)
        expect(f.conversation.getSnapshot().error).toContain("Retry latest history")
      late.resolve([5])
      await f.query.mock.results[0]!.value
      expect(f.db.get(f.db.ref(DbObjectKind.Message, cachedMessage(5).id))).toBeUndefined()
      expect(f.conversation.getSnapshot().historyCertified).toBe(false)
      if (hasCachedMessages) {
        expect(f.query).toHaveBeenCalledTimes(1)
        f.setHistory(async () => [100])
        await f.conversation.loadLatest()
      } else {
        authorized.resolve([100])
        await vi.waitFor(() => expect(f.conversation.getSnapshot().refreshingLatest).toBe(false))
      }
      expect(f.conversation.getSnapshot().messages.map((message) => message.messageId)).toEqual([
        messageId(100),
      ])
      expect(
        f.conversation.getSnapshot().historyCertified,
        f.conversation.getSnapshot().error,
      ).toBe(true)
      expect(f.conversation.getSnapshot().error).toBeUndefined()
      f.conversation.stop()
      await f.conversation.drain()
      await f.db.closePersistence()
    },
  )

  it.each(["edit", "delete"] as const)(
    "preserves an actual committed %s against an older pending history snapshot",
    async (action) => {
      const f = await fixture([cachedMessage(5)])
      const late = deferred<number[]>()
      f.setHistory(() => late.promise)
      await f.conversation.start()
      await f.db.commit(() => {
        applyUpdates(f.db, [
          action === "edit"
            ? Update.create({
                update: {
                  oneofKind: "editMessage",
                  editMessage: {
                    message: {
                      ...protocolMessage(5),
                      message: "Updated after request",
                      editDate: 100n,
                      rev: 2n,
                    },
                  },
                },
              })
            : Update.create({
                update: {
                  oneofKind: "deleteMessages",
                  deleteMessages: {
                    peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
                    messageIds: [5n],
                  },
                },
              }),
        ])
        f.db.replace({ ...f.db.get(f.db.ref(DbObjectKind.Chat, targetChat))! })
        f.db.replace({ kind: DbObjectKind.SyncBucketState, id: "user", seq: 1, date: 200 })
      })
      expect(f.conversation.getSnapshot().historyCertified).toBe(false)
      expect(f.conversation.getSnapshot().error).toContain("Retry latest history")
      late.resolve([5])
      await f.query.mock.results[0]!.value
      const current = f.db.get(f.db.ref(DbObjectKind.Message, cachedMessage(5).id))
      if (action === "edit")
        expect(current).toMatchObject({ message: "Updated after request", editDate: 100, rev: 2n })
      else expect(current).toBeUndefined()
      expect(f.conversation.getSnapshot().historyCertified).toBe(false)
      expect(f.query).toHaveBeenCalledTimes(1)
      f.conversation.stop()
      await f.db.closePersistence()
    },
  )

  it.each([false, true])(
    "refreshes once for user catchup after outgoing reconciliation (mapping already has user cursor %s)",
    async (mappingHasCursor) => {
      const f = await fixture()
      const syncStorage = new DbSyncStorage(f.db)
      const pages: Array<ReturnType<typeof deferred<(number | ProtocolMessage)[]>>> = []
      await openCertified(f.conversation)
      f.setHistory(() => {
        const page = deferred<(number | ProtocolMessage)[]>()
        pages.push(page)
        return page.promise
      })
      try {
        await f.conversation.setDraft("Queued before takeover")
        await f.conversation.send()
        await f.conversation.setDraft("Through handoff")
        const provisional = f.db
          .queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message)
          .find((message) => message.status === MessageSendingStatus.Sending)!
        const canonical: ProtocolMessage = {
          ...protocolMessage(101),
          fromId: 7n,
          out: true,
          date: BigInt(provisional.date!),
          message: provisional.message,
          rev: 0n,
        }
        const reconcile = () =>
          applyUpdates(f.db, [
            Update.create({
              update: {
                oneofKind: "updateMessageId",
                updateMessageId: { messageId: 101n, randomId: provisional.randomId! },
              },
            }),
            Update.create({
              update: { oneofKind: "newMessage", newMessage: { message: canonical } },
            }),
          ])
        if (mappingHasCursor) {
          expect(
            await syncStorage.commitBucketState({ kind: "user" }, { seq: 1, date: 200 }, reconcile),
          ).toBe(true)
          await vi.waitFor(() => expect(pages).toHaveLength(2))
        } else await f.db.commit(reconcile)

        // The RPC can reconcile before its sequenced push/catchup. The latter
        // publishes an authorized Chat sidecar plus cursor, without a temp row.
        expect(
          await syncStorage.commitBucketState({ kind: "user" }, { seq: 2, date: 201 }, () => {
            upsertChat(f.db, { id: 10n, title: "Team", lastMsgId: 101n, date: canonical.date })
            applyUpdates(f.db, [
              Update.create({
                update: {
                  oneofKind: "newMessage",
                  newMessage: { message: structuredClone(canonical) },
                },
              }),
            ])
          }),
        ).toBe(true)
        expect(f.conversation.getSnapshot().error).toBeUndefined()
        expect(f.conversation.getSnapshot().historyCertified).toBe(false)
        await vi.waitFor(() => expect(pages).toHaveLength(mappingHasCursor ? 3 : 2))
        for (const page of pages.slice(0, -1)) page.resolve([5])
        await Promise.all(f.query.mock.results.slice(1, -1).map((request) => request.value))
        expect(f.db.get(f.db.ref(DbObjectKind.Message, cachedMessage(5).id))).toBeUndefined()
        expect(f.conversation.getSnapshot().historyCertified).toBe(false)
        pages.at(-1)!.resolve([canonical])
        await vi.waitFor(() => expect(f.conversation.getSnapshot().refreshingLatest).toBe(false))
        expect(f.conversation.getSnapshot()).toMatchObject({
          error: undefined,
          historyCertified: true,
          atLatest: true,
          draft: "Through handoff",
        })
        expect(f.conversation.getSnapshot().messages.map((message) => message.messageId)).toEqual([
          messageId(101),
        ])
      } finally {
        pages.forEach((page) => page.resolve([]))
        f.conversation.stop()
        await f.conversation.drain()
        await Promise.all(f.query.mock.results.map((request) => request.value))
        await f.db.closePersistence()
      }
    },
  )

  it.each([
    [false, false],
    [true, false],
    [false, true],
  ])(
    "reconciles a local send with a user cursor and canonical duplicate during pending history (legacy positive ID %s, sparse canonical %s)",
    async (positiveTemporaryId, sparseCanonical) => {
      const f = await fixture()
      await openCertified(f.conversation)
      if (positiveTemporaryId) {
        f.mutateAccepted.mockImplementationOnce(async (transaction) => {
          ;(transaction.context as { temporaryMessageId: string }).temporaryMessageId =
            messageId(90)
          await f.db.commit(() => {
            transaction.optimistic?.(f.db, f.auth)
          })
        })
      }
      const oldPage = deferred<(number | ProtocolMessage)[]>()
      const freshPage = deferred<(number | ProtocolMessage)[]>()
      let latestRequests = 0
      f.setHistory(() => (++latestRequests === 1 ? oldPage.promise : freshPage.promise))
      await f.conversation.setDraft("A link https://inline.chat")
      await f.conversation.send()
      const provisional = f.db
        .queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message)
        .find((message) => message.status === MessageSendingStatus.Sending)!
      expect(provisional.randomId).toBeDefined()
      expect(f.db.get(f.db.ref(DbObjectKind.Chat, targetChat))?.lastMsgId).toBe(
        provisional.messageId,
      )
      const mappingWrite = deferred<void>()
      const durableWrite = f.store.write.bind(f.store)
      const writingMapping = vi
        .spyOn(f.store, "write")
        .mockImplementationOnce(async (operations) => {
          await mappingWrite.promise
          await durableWrite(operations)
        })
      const mapping = f.db.commit(() => {
        applyUpdates(f.db, [
          Update.create({
            update: {
              oneofKind: "updateMessageId",
              updateMessageId: { messageId: 101n, randomId: provisional.randomId! },
            },
          }),
        ])
        f.db.replace({ kind: DbObjectKind.SyncBucketState, id: "user", seq: 1, date: 200 })
      })
      await vi.waitFor(() => expect(writingMapping).toHaveBeenCalledTimes(1))
      // The cache read starts while durable storage still contains the old row;
      // Db serializes admission with the mapping commit rather than restoring it.
      const hydration = f.db.hydrateObjects(DbObjectKind.Message, [provisional.id])
      mappingWrite.resolve()
      await Promise.all([mapping, hydration])
      expect(f.db.get(f.db.ref(DbObjectKind.Message, provisional.id))).toBeUndefined()
      await vi.waitFor(() => expect(f.query).toHaveBeenCalledTimes(3))
      expect(f.conversation.getSnapshot().error).toBeUndefined()
      expect(f.conversation.getSnapshot().refreshingLatest).toBe(true)
      const canonical = ProtocolMessageCodec.fromBinary(
        ProtocolMessageCodec.toBinary(
          ProtocolMessageCodec.create({
            ...protocolMessage(101),
            fromId: 7n,
            out: true,
            date: BigInt(provisional.date! + 5),
            message: provisional.message,
            rev: sparseCanonical ? undefined : 0n,
            hasLink: true,
          }),
        ),
      )
      await f.db.commit(() => {
        applyUpdates(f.db, [
          Update.create({
            update: { oneofKind: "newMessage", newMessage: { message: canonical } },
          }),
        ])
      })
      await vi.waitFor(() => expect(f.query).toHaveBeenCalledTimes(4))
      await f.db.commit(() => {
        applyUpdates(f.db, [
          Update.create({
            update: {
              oneofKind: "newMessage",
              newMessage: { message: structuredClone(canonical) },
            },
          }),
        ])
        f.db.replace({ kind: DbObjectKind.SyncBucketState, id: "chat:10", seq: 1, date: 200 })
      })
      expect(f.conversation.getSnapshot().error).toBeUndefined()
      expect(f.query).toHaveBeenCalledTimes(4)
      oldPage.resolve([5])
      await f.query.mock.results[1]!.value
      expect(f.db.get(f.db.ref(DbObjectKind.Message, cachedMessage(5).id))).toBeUndefined()
      freshPage.resolve([canonical])
      await vi.waitFor(() => expect(f.conversation.getSnapshot().refreshingLatest).toBe(false))
      expect(f.conversation.getSnapshot().error).toBeUndefined()
      expect(f.conversation.getSnapshot().historyCertified).toBe(true)
      expect(f.conversation.getSnapshot().messages).toHaveLength(1)
      expect(f.conversation.getSnapshot().messages[0]).toMatchObject({
        messageId: messageId(101),
        status: MessageSendingStatus.Sent,
        message: provisional.message,
        hasLink: true,
        date: provisional.date! + 5,
      })
      expect(f.conversation.getSnapshot().messages[0]?.rev).toBe(canonical.rev)
      if (sparseCanonical) {
        const staleSparse = deferred<(number | ProtocolMessage)[]>()
        f.setHistory(() => staleSparse.promise)
        const refreshing = f.conversation.loadLatest()
        await f.db.commit(() => {
          applyUpdates(f.db, [
            Update.create({
              update: {
                oneofKind: "editMessage",
                editMessage: { message: { ...canonical, message: "Later sparse edit" } },
              },
            }),
          ])
        })
        expect(f.conversation.getSnapshot().error).toContain("Retry latest history")
        staleSparse.resolve([canonical])
        await refreshing
        expect(f.db.get(f.db.ref(DbObjectKind.Message, cachedMessage(101).id))?.message).toBe(
          "Later sparse edit",
        )
        expect(f.conversation.getSnapshot().historyCertified).toBe(false)
      }
      f.conversation.stop()
      await f.conversation.drain()
      await f.db.closePersistence()
    },
  )

  it("rejects a later revision edit with a suppressed edit timestamp after accepting canonical duplicates", async () => {
    const canonical: ProtocolMessage = {
      ...protocolMessage(5),
      out: true,
      fromId: 7n,
      rev: 0n,
      hasLink: true,
    }
    const f = await fixture()
    f.setHistory(async () => [canonical])
    await openCertified(f.conversation)
    const oldPage = deferred<(number | ProtocolMessage)[]>()
    f.setHistory(() => oldPage.promise)
    const refreshing = f.conversation.loadLatest()
    await f.db.commit(() => {
      applyUpdates(f.db, [
        Update.create({
          update: { oneofKind: "newMessage", newMessage: { message: structuredClone(canonical) } },
        }),
      ])
    })
    expect(f.conversation.getSnapshot().error).toBeUndefined()
    await f.db.commit(() => {
      applyUpdates(f.db, [
        Update.create({
          update: {
            oneofKind: "editMessage",
            editMessage: {
              message: { ...canonical, rev: 1n, message: "Edited without timestamp" },
            },
          },
        }),
      ])
    })
    expect(f.conversation.getSnapshot().error).toContain("Retry latest history")
    oldPage.resolve([canonical])
    await refreshing
    expect(f.db.get(f.db.ref(DbObjectKind.Message, cachedMessage(5).id))).toMatchObject({
      rev: 1n,
      message: "Edited without timestamp",
      editDate: undefined,
    })
    expect(f.conversation.getSnapshot().historyCertified).toBe(false)
    f.conversation.stop()
    await f.db.closePersistence()
  })

  it("consumes sparse first canonicalization even when equal and rejects a later nested-field edit during the same pending page", async () => {
    const f = await fixture()
    await openCertified(f.conversation)
    const stale = deferred<(number | ProtocolMessage)[]>()
    f.setHistory(() => stale.promise)
    await f.conversation.setDraft("Same body")
    await f.conversation.send()
    const provisional = f.db
      .queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message)
      .find((message) => message.status === MessageSendingStatus.Sending)!
    await f.db.commit(() => {
      applyUpdates(f.db, [
        Update.create({
          update: {
            oneofKind: "updateMessageId",
            updateMessageId: { messageId: 101n, randomId: provisional.randomId! },
          },
        }),
      ])
      f.db.replace({ kind: DbObjectKind.SyncBucketState, id: "user", seq: 1, date: 200 })
    })
    await vi.waitFor(() => expect(f.query).toHaveBeenCalledTimes(3))
    const sparse = ProtocolMessageCodec.fromBinary(
      ProtocolMessageCodec.toBinary(
        ProtocolMessageCodec.create({
          ...protocolMessage(101),
          fromId: 7n,
          out: true,
          date: BigInt(provisional.date!),
          message: provisional.message,
        }),
      ),
    )
    expect(sparse.rev).toBeUndefined()
    await f.db.commit(() => {
      applyUpdates(f.db, [
        Update.create({ update: { oneofKind: "newMessage", newMessage: { message: sparse } } }),
      ])
    })
    expect(f.conversation.getSnapshot().error).toBeUndefined()
    await f.db.commit(() => {
      applyUpdates(f.db, [
        Update.create({
          update: {
            oneofKind: "editMessage",
            editMessage: {
              message: {
                ...sparse,
                entities: {
                  entities: [{ type: 5, offset: 0n, length: 4n, entity: { oneofKind: undefined } }],
                },
              },
            },
          },
        }),
      ])
    })
    expect(f.conversation.getSnapshot().error).toContain("Retry latest history")
    stale.resolve([sparse])
    await Promise.all(f.query.mock.results.slice(1).map((result) => result.value))
    expect(
      f.db.get(f.db.ref(DbObjectKind.Message, cachedMessage(101).id))?.entities?.entities[0]
        ?.length,
    ).toBe(4n)
    expect(f.conversation.getSnapshot().historyCertified).toBe(false)
    expect(f.query).toHaveBeenCalledTimes(3)
    f.conversation.stop()
    await f.conversation.drain()
    await f.db.closePersistence()
  })

  it("discards stale pages and refreshes once for ambiguous sparse metadata after atomic mapping and canonical push", async () => {
    const f = await fixture()
    await openCertified(f.conversation)
    const stale = deferred<(number | ProtocolMessage)[]>()
    const fresh = deferred<(number | ProtocolMessage)[]>()
    let requests = 0
    f.setHistory(() => (++requests <= 2 ? stale.promise : fresh.promise))
    await f.conversation.setDraft("Atomic sparse acknowledgement")
    await f.conversation.send()
    const provisional = f.db
      .queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message)
      .find((message) => message.status === MessageSendingStatus.Sending)!
    const sparse = ProtocolMessageCodec.fromBinary(
      ProtocolMessageCodec.toBinary(
        ProtocolMessageCodec.create({
          ...protocolMessage(101),
          fromId: 7n,
          out: true,
          date: BigInt(provisional.date!),
          message: provisional.message,
        }),
      ),
    )
    await f.db.commit(() => {
      applyUpdates(f.db, [
        Update.create({
          update: {
            oneofKind: "updateMessageId",
            updateMessageId: { messageId: 101n, randomId: provisional.randomId! },
          },
        }),
        Update.create({ update: { oneofKind: "newMessage", newMessage: { message: sparse } } }),
      ])
      f.db.replace({ kind: DbObjectKind.SyncBucketState, id: "user", seq: 1, date: 200 })
    })
    await vi.waitFor(() => expect(f.query).toHaveBeenCalledTimes(3))
    expect(f.conversation.getSnapshot().error).toBeUndefined()
    const updated: ProtocolMessage = {
      ...sparse,
      entities: {
        entities: [{ type: 5, offset: 0n, length: 6n, entity: { oneofKind: undefined } }],
      },
    }
    await f.db.commit(() => {
      applyUpdates(f.db, [
        Update.create({ update: { oneofKind: "editMessage", editMessage: { message: updated } } }),
      ])
    })
    await vi.waitFor(() => expect(f.query).toHaveBeenCalledTimes(4))
    expect(f.conversation.getSnapshot().error).toBeUndefined()
    expect(f.conversation.getSnapshot().historyCertified).toBe(false)
    stale.resolve([sparse])
    await Promise.all(f.query.mock.results.slice(1, 3).map((result) => result.value))
    expect(
      f.db.get(f.db.ref(DbObjectKind.Message, cachedMessage(101).id))?.entities?.entities[0]
        ?.length,
    ).toBe(6n)
    expect(f.conversation.getSnapshot().historyCertified).toBe(false)
    fresh.resolve([updated])
    await vi.waitFor(() => expect(f.conversation.getSnapshot().refreshingLatest).toBe(false))
    expect(f.conversation.getSnapshot().historyCertified).toBe(true)
    expect(f.conversation.getSnapshot().messages[0]?.entities?.entities[0]?.length).toBe(6n)
    f.conversation.stop()
    await f.conversation.drain()
    await f.db.closePersistence()
  })

  it("retains visible draft text and reports persistence failure", async () => {
    const f = await fixture()
    await openCertified(f.conversation)
    vi.spyOn(f.store, "write").mockRejectedValueOnce(new Error("disk full"))
    await expect(f.conversation.setDraft("Unsaved")).rejects.toThrow("disk full")
    expect(f.conversation.getSnapshot().draft).toBe("Unsaved")
    expect(f.conversation.getSnapshot().draftError).toContain("Draft was not saved")
    expect(f.db.get(f.db.ref(DbObjectKind.MessageDraft, draftId))).toBeUndefined()
    f.conversation.stop()
    await expect(f.conversation.drain()).rejects.toThrow("disk full")
    await f.db.closePersistence()
  })

  it("retries the unsaved visible draft after storage recovery and prepares its saved text on reopen", async () => {
    const f = await fixture()
    await openCertified(f.conversation)
    const write = vi.spyOn(f.store, "write").mockRejectedValueOnce(new Error("disk full"))
    await expect(f.conversation.setDraft("Recover this draft")).rejects.toThrow("disk full")
    const warning = f.conversation.getSnapshot().draftError
    await f.conversation.loadLatest()
    expect(f.conversation.getSnapshot().draftError).toBe(warning)
    expect(f.conversation.getSnapshot().draft).toBe("Recover this draft")
    write.mockRejectedValueOnce(new Error("still full"))
    await expect(f.conversation.retryError()).rejects.toThrow("still full")
    expect(f.conversation.getSnapshot().draftError).toContain("still full")
    const historyRequests = f.query.mock.calls.length
    await f.conversation.retryError()
    expect(f.query).toHaveBeenCalledTimes(historyRequests)
    expect(f.conversation.getSnapshot().draftError).toBeUndefined()
    expect(f.db.get(f.db.ref(DbObjectKind.MessageDraft, draftId))?.text).toBe("Recover this draft")
    f.conversation.stop()
    await f.conversation.drain()
    await f.db.closePersistence()
    const reopenedDb = new Db({ autoHydrate: false, persistenceStore: f.store })
    await reopenedDb.hydrateObjects(DbObjectKind.Chat, [targetChat])
    const network = deferred<RpcResult["result"]>()
    const reopened = new Conversation(
      reopenedDb,
      { query: () => network.promise } as unknown as RealtimeService,
      chat,
    )
    await reopened.start()
    expect(reopened.getSnapshot().draft).toBe("Recover this draft")
    expect(reopened.getSnapshot().draftError).toBeUndefined()
    reopened.stop()
    network.resolve({ oneofKind: "getChatHistory", getChatHistory: { messages: [] } })
    await reopened.drain()
    await reopenedDb.closePersistence()
  })

  it("accepts an unsaved draft into the durable send and clears its obsolete failed draft drain", async () => {
    const f = await fixture()
    await openCertified(f.conversation)
    vi.spyOn(f.store, "write").mockRejectedValueOnce(new Error("disk full"))
    await expect(f.conversation.setDraft("Send this retained text")).rejects.toThrow("disk full")
    await f.conversation.send()
    expect(f.conversation.getSnapshot().draft).toBe("")
    expect(f.conversation.getSnapshot().draftError).toBeUndefined()
    expect(
      f.db
        .queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message)
        .some((message) => message.message === "Send this retained text"),
    ).toBe(true)
    f.conversation.stop()
    await f.conversation.drain()
    await f.db.closePersistence()
  })

  it("drains rapid draft writes through retirement and storage close before reopened first-frame preparation", async () => {
    const f = await fixture([cachedMessage(5)])
    await openCertified(f.conversation)
    const blocked = deferred<void>()
    const write = f.store.write.bind(f.store)
    const writes = vi.spyOn(f.store, "write").mockImplementationOnce(async (operations) => {
      await blocked.promise
      await write(operations)
    })
    const first = f.conversation.setDraft("A")
    const middle = f.conversation.setDraft("AB")
    const last = f.conversation.setDraft("ABC saved for reopening")
    await vi.waitFor(() => expect(writes).toHaveBeenCalledTimes(1))
    expect(f.conversation.getSnapshot().draft).toBe("ABC saved for reopening")
    f.conversation.stop()
    expect(f.db.fullChatWindows.isActive(targetChat)).toBe(false)
    await expect(f.conversation.setDraft("After retirement")).rejects.toThrow("closed")
    let closed = false
    const closing = f.conversation.drain().then(async () => {
      await f.db.closePersistence()
      closed = true
    })
    await Promise.resolve()
    expect(closed).toBe(false)
    blocked.resolve()
    await Promise.all([first, middle, last, closing])
    expect(closed).toBe(true)
    expect(writes).toHaveBeenCalledTimes(3)
    const reopenedDb = new Db({ autoHydrate: false, persistenceStore: f.store })
    await reopenedDb.hydrateObjects(DbObjectKind.Chat, [targetChat])
    const network = deferred<RpcResult["result"]>()
    const realtime = { query: () => network.promise } as unknown as RealtimeService
    const reopened = new Conversation(reopenedDb, realtime, chat)
    await reopened.start()
    expect(reopened.getSnapshot().draft).toBe("ABC saved for reopening")
    expect(reopened.getSnapshot().loading).toBe(false)
    expect(reopened.getSnapshot().historyCertified).toBe(false)
    reopened.stop()
    network.resolve({ oneofKind: "getChatHistory", getChatHistory: { messages: [] } })
    await reopened.drain()
    await reopenedDb.closePersistence()
  })

  it("commits a consumed draft with local send acceptance and preserves new typing during acceptance", async () => {
    const f = await fixture()
    await openCertified(f.conversation)
    await f.conversation.setDraft("First")
    const accepting = deferred<void>()
    f.mutateAccepted.mockImplementationOnce(async (transaction) => {
      await accepting.promise
      await f.db.commit(() => {
        transaction.optimistic?.(f.db, f.auth)
      })
    })
    const sending = f.conversation.send()
    await vi.waitFor(() => expect(f.mutateAccepted).toHaveBeenCalledTimes(1))
    await f.conversation.setDraft("Second")
    accepting.resolve()
    await sending
    expect(f.conversation.getSnapshot().draft).toBe("Second")
    expect(f.db.get(f.db.ref(DbObjectKind.MessageDraft, draftId))?.text).toBe("Second")
    // Accepting this second draft deletes it in the exact local message commit.
    await f.conversation.send()
    expect(f.conversation.getSnapshot().draft).toBe("")
    expect(f.db.get(f.db.ref(DbObjectKind.MessageDraft, draftId))).toBeUndefined()
    f.conversation.stop()
    await f.db.closePersistence()
  })

  it("rolls back message and draft together when local send persistence fails", async () => {
    const f = await fixture()
    await openCertified(f.conversation)
    await f.conversation.setDraft("Keep me")
    vi.spyOn(f.store, "write").mockRejectedValueOnce(new Error("write refused"))
    await expect(f.conversation.send()).rejects.toThrow("write refused")
    expect(f.conversation.getSnapshot().draft).toBe("Keep me")
    expect(f.db.get(f.db.ref(DbObjectKind.MessageDraft, draftId))?.text).toBe("Keep me")
    expect(f.db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message)).toHaveLength(0)
    f.conversation.stop()
    await f.db.closePersistence()
  })

  it("retries failed local send acceptance with the retained compose rather than a history refresh", async () => {
    const f = await fixture()
    await openCertified(f.conversation)
    await f.conversation.setDraft("Send again after recovery")
    vi.spyOn(f.store, "write").mockRejectedValueOnce(new Error("write refused"))
    await expect(f.conversation.send()).rejects.toThrow("write refused")
    expect(f.conversation.getSnapshot().errorRetry).toEqual({ kind: "send" })
    expect(f.conversation.getSnapshot().draft).toBe("Send again after recovery")
    await f.conversation.retryError()
    expect(f.mutateAccepted).toHaveBeenCalledTimes(2)
    expect(
      f.db
        .queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message)
        .map((message) => message.message),
    ).toEqual(["Send again after recovery"])
    expect(f.conversation.getSnapshot().draft).toBe("")
    expect(f.conversation.getSnapshot().error).toBeUndefined()
    f.conversation.stop()
    await f.conversation.drain()
    await f.db.closePersistence()
  })

  it("retries a failed resend against the original message rather than loading history", async () => {
    const f = await fixture()
    await openCertified(f.conversation)
    f.resendMessage.mockRejectedValueOnce(new Error("cannot save retry"))
    await expect(f.conversation.retry(messageId(-1))).rejects.toThrow("cannot save retry")
    expect(f.conversation.getSnapshot().errorRetry).toEqual({
      kind: "resend",
      messageId: messageId(-1),
    })
    expect(f.query).toHaveBeenCalledTimes(1)
    await f.conversation.retryError()
    expect(f.resendMessage.mock.calls).toEqual([
      [targetChat, messageId(-1)],
      [targetChat, messageId(-1)],
    ])
    expect(f.query).toHaveBeenCalledTimes(2)
    expect(f.conversation.getSnapshot().error).toBeUndefined()
    f.conversation.stop()
    await f.db.closePersistence()
  })

  it("accepts durable sends while latest history is waiting for the network", async () => {
    const f = await fixture([cachedMessage(5)])
    const network = deferred<number[]>()
    f.setHistory(() => network.promise)
    const opening = f.conversation.start()
    await vi.waitFor(() => expect(f.query).toHaveBeenCalledTimes(1))
    expect(f.conversation.getSnapshot().loading).toBe(false)
    expect(f.conversation.getSnapshot().refreshingLatest).toBe(true)
    expect(f.conversation.getSnapshot().historyCertified).toBe(false)
    await f.conversation.setDraft("Offline send")
    await f.conversation.send()
    expect(f.mutateAccepted).toHaveBeenCalledTimes(1)
    expect(f.conversation.getSnapshot().draft).toBe("")
    network.resolve([5])
    await opening
    await vi.waitFor(() => expect(f.conversation.getSnapshot().refreshingLatest).toBe(false))
    f.conversation.stop()
    await f.db.closePersistence()
  })

  it("does not resurrect an accepted draft when its conversation reopens before acceptance", async () => {
    const f = await fixture()
    await openCertified(f.conversation)
    await f.conversation.setDraft("In flight")
    const accepting = deferred<void>()
    f.mutateAccepted.mockImplementationOnce(async (transaction) => {
      await accepting.promise
      await f.db.commit(() => {
        transaction.optimistic?.(f.db, f.auth)
      })
    })
    const sending = f.conversation.send()
    await vi.waitFor(() => expect(f.mutateAccepted).toHaveBeenCalledTimes(1))
    f.conversation.stop()
    const reopened = new Conversation(f.db, f.realtime, chat)
    await openCertified(reopened)
    expect(reopened.getSnapshot().draft).toBe("In flight")
    accepting.resolve()
    await sending
    expect(reopened.getSnapshot().draft).toBe("")
    expect(f.db.get(f.db.ref(DbObjectKind.MessageDraft, draftId))).toBeUndefined()
    reopened.stop()
    await f.db.closePersistence()
  })

  it("retains concurrent confirmed messages while older and latest history responses settle", async () => {
    const f = await fixture()
    f.setHistory(async () => ids(40, 100))
    await openCertified(f.conversation)
    const older = deferred<number[]>()
    f.setHistory(() => older.promise)
    const loadingOlder = f.conversation.loadOlder()
    await vi.waitFor(() => expect(f.query).toHaveBeenCalledTimes(2))
    await f.db.commit(() => {
      f.db.insert(cachedMessage(101))
      f.db.replace({ ...chat, lastMsgId: messageId(101), date: 101 })
      f.db.includeMessageInActiveLatestWindow(cachedMessage(101))
    })
    older.resolve(ids(1, 40))
    await loadingOlder
    expect(f.conversation.getSnapshot().messages.at(-1)?.messageId).toBe(messageId(101))
    const latest = deferred<number[]>()
    f.setHistory(() => latest.promise)
    const refreshing = f.conversation.loadLatest()
    await vi.waitFor(() => expect(f.query).toHaveBeenCalledTimes(3))
    await f.db.commit(() => {
      f.db.insert(cachedMessage(102))
      f.db.replace({ ...chat, lastMsgId: messageId(102), date: 102 })
      f.db.includeMessageInActiveLatestWindow(cachedMessage(102))
    })
    latest.resolve(ids(41, 101))
    await refreshing
    expect(f.conversation.getSnapshot().messages.at(-1)?.messageId).toBe(messageId(102))
    f.conversation.stop()
    await f.db.closePersistence()
  })

  it("uses the real outbox local commit while network history and send delivery are pending", async () => {
    const store = createIndexedDbPersistenceStore(
      `conversation-real-client-${crypto.randomUUID()}`,
    )!
    const db = new Db({ autoHydrate: false, persistenceStore: store })
    await db.commit(() => {
      db.insert(chat)
    })
    const auth = new AuthStore()
    const client = new RealtimeClient({ auth, db, transport: new MockTransport(), sync: false })
    await client.startSession({ token: "conversation-test", userId: userId(7) })
    const conversation = new Conversation(db, client, chat)
    const opening = conversation.start()
    await vi.waitFor(() => expect(conversation.getSnapshot().loading).toBe(false))
    await conversation.setDraft("Real outbox")
    await conversation.send()
    const pending = db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.PendingTransaction)
    expect(pending.filter((record) => record.type === "send_message")).toHaveLength(1)
    expect(db.get(db.ref(DbObjectKind.MessageDraft, draftId))).toBeUndefined()
    expect(conversation.getSnapshot().draft).toBe("")
    expect(
      conversation.getSnapshot().messages.some((message) => message.message === "Real outbox"),
    ).toBe(true)
    conversation.stop()
    await client.stop()
    await opening
    await db.closePersistence()
  })

  it("refreshes latest server coverage and its older cursor after a real resend promotes a bounded historical window", async () => {
    const f = await fixture()
    const transport = new MockTransport()
    const client = new RealtimeClient({ auth: f.auth, db: f.db, transport, sync: false })
    await client.startSession({ token: "conversation-test", userId: userId(7) })
    await transport.connect()
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 1n,
        body: { oneofKind: "connectionOpen", connectionOpen: {} },
      }),
    )
    const failedSend = client.execute(
      sendMessage({
        chatId: targetChat,
        peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
        text: "Retry from older history",
        temporaryMessageId: messageId(-9),
        temporarySendDate: 300,
      }),
    )
    const failed = expect(failedSend).rejects.toBeDefined()
    const requests = () =>
      transport.sent.filter(
        (message) =>
          message.body.oneofKind === "rpcCall" &&
          message.body.rpcCall.method === Method.SEND_MESSAGE,
      )
    await vi.waitFor(() => expect(requests()).toHaveLength(1))
    const firstRequest = requests()[0]!
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 2n,
        body: {
          oneofKind: "rpcError",
          rpcError: {
            reqMsgId: firstRequest.id,
            code: 400,
            errorCode: RpcError_Code.BAD_REQUEST,
            message: "SEND_FAILED",
          },
        },
      }),
    )
    await failed
    expect(
      f.db.get(f.db.ref(DbObjectKind.Message, messageKey(targetChat, messageId(-9))))?.status,
    ).toBe(MessageSendingStatus.Failed)
    const pending = f.db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.PendingTransaction,
    )[0]!
    let latestId = 500
    const olderCursors: string[] = []
    const acknowledged: ProtocolMessage = {
      ...protocolMessage(501),
      fromId: 7n,
      out: true,
      message: "Retry from older history",
      rev: 0n,
    }
    f.setHistory(async (transaction) => {
      const context = transaction.context as { beforeId?: string }
      if (context.beforeId != null) olderCursors.push(context.beforeId)
      const tail = context.beforeId == null ? latestId : Number(context.beforeId) - 1
      return ids(tail - 60, tail).map((id) => (id === 501 ? acknowledged : id))
    })
    f.resendMessage.mockImplementation((chatId, messageId) =>
      client.resendMessage(chatId, messageId),
    )
    await openCertified(f.conversation)
    for (let page = 0; page < 4; page++) await f.conversation.loadOlder()
    expect(f.conversation.getSnapshot().messages).toHaveLength(200)
    expect(f.conversation.getSnapshot().atLatest).toBe(false)
    expect(
      f.conversation.getSnapshot().messages.some((message) => message.messageId === messageId(-9)),
    ).toBe(true)
    const resending = f.conversation.retry(messageId(-9))
    await vi.waitFor(() => expect(requests()).toHaveLength(2))
    expect(f.conversation.getSnapshot().hasOlder).toBe(false)
    expect(f.conversation.getSnapshot().historyCertified).toBe(false)
    expect(
      f.db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.PendingTransaction)[0]?.id,
    ).toBe(pending.id)
    const secondRequest = requests()[1]!
    if (
      secondRequest.body.oneofKind !== "rpcCall" ||
      secondRequest.body.rpcCall.input.oneofKind !== "sendMessage"
    )
      throw new Error("Missing actual resend request")
    latestId = 501
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 3n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: secondRequest.id,
            result: {
              oneofKind: "sendMessage",
              sendMessage: {
                updates: [
                  Update.create({
                    update: {
                      oneofKind: "updateMessageId",
                      updateMessageId: {
                        messageId: 501n,
                        randomId: secondRequest.body.rpcCall.input.sendMessage.randomId!,
                      },
                    },
                  }),
                  Update.create({
                    update: { oneofKind: "newMessage", newMessage: { message: acknowledged } },
                  }),
                ],
              },
            },
          },
        },
      }),
    )
    await resending
    await vi.waitFor(() => expect(f.conversation.getSnapshot().refreshingLatest).toBe(false))
    expect(f.conversation.getSnapshot().error).toBeUndefined()
    expect(f.conversation.getSnapshot().historyCertified).toBe(true)
    expect(f.conversation.getSnapshot().atLatest).toBe(true)
    expect(f.conversation.getSnapshot().messages.map((message) => message.messageId)).toEqual(
      ids(442, 501).map(messageId),
    )
    await f.conversation.loadOlder()
    expect(olderCursors.at(-1)).toBe(messageId(442))
    expect(f.conversation.getSnapshot().messages.map((message) => message.messageId)).toEqual(
      ids(382, 501).map(messageId),
    )
    f.conversation.stop()
    await client.stop()
    await f.db.closePersistence()
  })

  it("delegates retry to the existing outbox identity", async () => {
    const f = await fixture()
    await openCertified(f.conversation)
    await f.conversation.retry(messageId(9_000))
    expect(f.resendMessage).toHaveBeenCalledWith(targetChat, messageId(9_000))
    expect(f.mutateAccepted).not.toHaveBeenCalled()
    f.conversation.stop()
    await f.db.closePersistence()
  })
})
