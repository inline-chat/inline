import "fake-indexeddb/auto"
import {
  AuthStore,
  Db,
  DbObjectKind,
  DbQueryPlanType,
  createIndexedDbPersistenceStore,
  messageDraftKey,
  messageKey,
  type Chat,
  type Message,
  type RealtimeService,
  type Transaction,
} from "@inline/client/core"
import { Method, type Message as ProtocolMessage, type RpcResult } from "@inline-chat/protocol/core"
import { chatId, messageId, protocolId, userId, type ChatID } from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { Account } from "./core"
import { ConversationNavigation } from "./navigation"

const chatA: Chat = { kind: DbObjectKind.Chat, id: chatId(10), title: "A" }
const chatB: Chat = { kind: DbObjectKind.Chat, id: chatId(20), title: "B" }
const draftA = messageDraftKey({ peerKind: "chat", peerThreadId: chatA.id })

const cachedMessage = (chat: ChatID, id: number): Message => ({
  kind: DbObjectKind.Message,
  id: messageKey(chat, messageId(id)),
  chatId: chat,
  messageId: messageId(id),
  fromId: userId(8),
  date: id,
  message: `Message ${id}`,
})

const serverMessage = (chat: ChatID, id: number): ProtocolMessage => ({
  id: BigInt(id),
  chatId: protocolId(chat),
  fromId: 8n,
  date: BigInt(id),
  message: `Message ${id}`,
  out: false,
})

const deferred = <T>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => {
    resolve = done
  })
  return { promise, resolve }
}

const fixtures: Array<{
  navigation: ConversationNavigation
  db: Db
  requests: Array<{ response: ReturnType<typeof deferred<ProtocolMessage[]>> }>
  query: { mock: { results: Array<{ value: unknown }> } }
}> = []

/** Reopen a real IndexedDB cache; only the server response is controlled. */
const fixture = async () => {
  const name = `navigation-test-${crypto.randomUUID()}`
  const writer = new Db({
    autoHydrate: false,
    persistenceStore: createIndexedDbPersistenceStore(name)!,
  })
  await writer.commit(() => {
    writer.insert(chatA)
    writer.insert(chatB)
    writer.insert(cachedMessage(chatA.id, 5))
    writer.insert(cachedMessage(chatB.id, 8))
    writer.insert({
      kind: DbObjectKind.MessageDraft,
      id: draftA,
      peerKind: "chat",
      peerThreadId: chatA.id,
      text: "Saved draft",
      revision: 1,
      updatedAt: 1,
    })
  })
  await writer.closePersistence()
  const store = createIndexedDbPersistenceStore(name)!
  const db = new Db({ autoHydrate: false, persistenceStore: store })
  await db.hydrateKinds([DbObjectKind.Chat])
  const auth = new AuthStore()
  await auth.ready
  await auth.login({ token: "navigation-test", userId: userId(7) })
  const requests: Array<{
    chat: ChatID
    response: ReturnType<typeof deferred<ProtocolMessage[]>>
  }> = []
  const query = vi.fn(async (transaction: Transaction) => {
    if (transaction.method !== Method.GET_CHAT_HISTORY)
      throw new Error("Unexpected metadata fetch for a cached chat")
    const input = transaction.input(transaction.context)
    if (
      input.oneofKind !== "getChatHistory" ||
      input.getChatHistory.peerId?.type.oneofKind !== "chat"
    ) {
      throw new Error("Expected a chat history request")
    }
    transaction.beforeExecute?.(db)
    const request = {
      chat: chatId(input.getChatHistory.peerId.type.chat.chatId),
      response: deferred<ProtocolMessage[]>(),
    }
    requests.push(request)
    const result: RpcResult["result"] = {
      oneofKind: "getChatHistory",
      getChatHistory: { messages: await request.response.promise },
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
  const realtime = { query, mutateAccepted } as unknown as RealtimeService
  const navigation = new ConversationNavigation({ db, realtime } as unknown as Account)
  const result = { db, store, query, mutateAccepted, auth, requests, navigation }
  fixtures.push(result)
  return result
}

afterEach(async () => {
  for (const f of fixtures.splice(0)) {
    f.navigation.close()
    for (const request of f.requests) request.response.resolve([])
    await Promise.allSettled(f.query.mock.results.map((result) => result.value))
    await f.db.closePersistence()
  }
  vi.restoreAllMocks()
})

describe("ConversationNavigation", () => {
  it("returns cached messages and the persisted draft before network history settles", async () => {
    const f = await fixture()
    expect(f.db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message)).toEqual([])
    expect(f.db.get(f.db.ref(DbObjectKind.MessageDraft, draftA))).toBeUndefined()

    const opened = await f.navigation.open(chatA.id, new AbortController().signal)

    expect(opened.chat).toEqual(chatA)
    expect(opened.conversation.getSnapshot()).toMatchObject({
      loading: false,
      refreshingLatest: true,
      historyCertified: false,
      draft: "Saved draft",
    })
    expect(opened.conversation.getSnapshot().messages.map((message) => message.messageId)).toEqual([
      messageId(5),
    ])
    expect(f.requests.map((request) => request.chat)).toEqual([chatA.id])
    expect(f.db.fullChatWindows.isActive(chatA.id)).toBe(true)

    f.requests[0]!.response.resolve([serverMessage(chatA.id, 100)])
    await vi.waitFor(() => expect(opened.conversation.getSnapshot().historyCertified).toBe(true))
    expect(opened.conversation.getSnapshot().messages.map((message) => message.messageId)).toEqual([
      messageId(100),
    ])
  })

  it("waits for cached preparation when the same chat is opened again during its first loader", async () => {
    const f = await fixture()
    const cache = deferred<Message[]>()
    const readCache = vi
      .spyOn(f.store.collection(DbObjectKind.Message), "getMessageWindowByChatId")
      .mockImplementationOnce(() => cache.promise)
    const firstOpening = f.navigation.open(chatA.id, new AbortController().signal)
    await vi.waitFor(() => expect(readCache).toHaveBeenCalledTimes(1))
    let secondReturned = false
    const secondOpening = f.navigation
      .open(chatA.id, new AbortController().signal)
      .then((opened) => {
        secondReturned = true
        return opened
      })
    await Promise.resolve()
    const returnedBeforeCache = secondReturned
    cache.resolve([cachedMessage(chatA.id, 5)])
    const [first, second] = await Promise.all([firstOpening, secondOpening])

    expect(returnedBeforeCache).toBe(false)
    expect(second).toBe(first)
    expect(second.conversation.getSnapshot().loading).toBe(false)
    expect(second.conversation.getSnapshot().messages.map((message) => message.messageId)).toEqual([
      messageId(5),
    ])
    expect(f.query).toHaveBeenCalledTimes(1)
  })

  it("retires A before B and preserves the reopened A window when an old cache loader finishes", async () => {
    const f = await fixture()
    const oldCache = deferred<Message[]>()
    const readCache = vi
      .spyOn(f.store.collection(DbObjectKind.Message), "getMessageWindowByChatId")
      .mockImplementationOnce(() => oldCache.promise)
    const activate = vi.spyOn(f.db, "activateResidentMessageWindow")
    const release = vi.spyOn(f.db, "releaseResidentMessageWindow")
    const oldOpening = f.navigation.open(chatA.id, new AbortController().signal)
    // Attach the rejection handler before letting superseded preparation settle.
    const oldResult = oldOpening.then(
      () => undefined,
      (error: unknown) => error,
    )
    await vi.waitFor(() => expect(readCache).toHaveBeenCalledTimes(1))

    const openedB = await f.navigation.open(chatB.id, new AbortController().signal)
    expect(openedB.conversation.getSnapshot().messages.map((message) => message.messageId)).toEqual(
      [messageId(8)],
    )
    expect(f.db.fullChatWindows.isActive(chatA.id)).toBe(false)
    const openedA = await f.navigation.open(chatA.id, new AbortController().signal)
    // History refresh also checks activation idempotently. Track the calls that
    // actually acquire a window rather than prescribing the number of checks.
    const acquisitions = activate.mock.calls.flatMap(([id], index) =>
      activate.mock.results[index]?.value === true
        ? [{ id, order: activate.mock.invocationCallOrder[index]! }]
        : [],
    )
    expect(acquisitions.map(({ id }) => id)).toEqual([chatA.id, chatB.id, chatA.id])
    expect(release.mock.calls.map(([id]) => id)).toEqual([chatA.id, chatB.id])
    expect(release.mock.invocationCallOrder[0]).toBeLessThan(acquisitions[1]!.order)
    expect(release.mock.invocationCallOrder[1]).toBeLessThan(acquisitions[2]!.order)

    f.requests[1]!.response.resolve([serverMessage(chatA.id, 100)])
    await vi.waitFor(() => expect(openedA.conversation.getSnapshot().historyCertified).toBe(true))
    const currentWindow = f.db.fullChatWindows.keys(chatA.id)
    const currentIntent = f.db.captureResidentMessageWindowIntents().get(chatA.id)
    oldCache.resolve([cachedMessage(chatA.id, 5)])
    expect(await oldResult).toMatchObject({ name: "AbortError" })

    expect(release.mock.calls.map(([id]) => id)).toEqual([chatA.id, chatB.id])
    expect(f.db.fullChatWindows.isActive(chatA.id)).toBe(true)
    expect(f.db.fullChatWindows.isActive(chatB.id)).toBe(false)
    expect(f.db.fullChatWindows.keys(chatA.id)).toEqual(currentWindow)
    expect(f.db.captureResidentMessageWindowIntents().get(chatA.id)).toBe(currentIntent)
    expect(openedA.conversation.getSnapshot().messages.map((message) => message.messageId)).toEqual(
      [messageId(100)],
    )
    expect(f.query).toHaveBeenCalledTimes(2)

    await f.db.commit(() => {
      f.db.replace({ ...cachedMessage(chatA.id, 100), message: "Current owner still observes" })
    })
    expect(openedA.conversation.getSnapshot().messages[0]?.message).toBe(
      "Current owner still observes",
    )
  })

  it("ignores stale route cleanup and history after A is reopened through B", async () => {
    const f = await fixture()
    const oldSignal = new AbortController()
    const oldA = await f.navigation.open(chatA.id, oldSignal.signal)
    const openedB = await f.navigation.open(chatB.id, new AbortController().signal)
    const openedA = await f.navigation.open(chatA.id, new AbortController().signal)
    expect(openedA.conversation).not.toBe(oldA.conversation)
    const stoppedA = oldA.conversation.getSnapshot()
    const stoppedB = openedB.conversation.getSnapshot()
    f.requests[2]!.response.resolve([serverMessage(chatA.id, 100)])
    await vi.waitFor(() => expect(openedA.conversation.getSnapshot().historyCertified).toBe(true))

    // Router cleanup is scoped to the exact Conversation it originally opened.
    f.navigation.close(oldA.conversation)
    f.navigation.close(openedB.conversation)
    oldSignal.abort()
    f.requests[0]!.response.resolve([serverMessage(chatA.id, 500)])
    f.requests[1]!.response.resolve([serverMessage(chatB.id, 800)])
    await Promise.all(f.query.mock.results.slice(0, 2).map((result) => result.value))

    expect(f.db.fullChatWindows.isActive(chatA.id)).toBe(true)
    expect(f.db.fullChatWindows.keys(chatA.id)).toEqual([messageKey(chatA.id, messageId(100))])
    expect(
      f.db.get(f.db.ref(DbObjectKind.Message, messageKey(chatA.id, messageId(500)))),
    ).toBeUndefined()
    expect(
      f.db.get(f.db.ref(DbObjectKind.Message, messageKey(chatB.id, messageId(800)))),
    ).toBeUndefined()
    expect(openedA.conversation.getSnapshot().messages.map((message) => message.messageId)).toEqual(
      [messageId(100)],
    )
    expect(oldA.conversation.getSnapshot()).toBe(stoppedA)
    expect(openedB.conversation.getSnapshot()).toBe(stoppedB)
    expect(await f.navigation.open(chatA.id, new AbortController().signal)).toBe(openedA)
  })

  it("surfaces failed retirement then retries the stopped pane's accepted draft before later navigation", async () => {
    const f = await fixture()
    const oldA = await f.navigation.open(chatA.id, new AbortController().signal)
    const durableWrite = f.store.write.bind(f.store)
    const writes = vi.spyOn(f.store, "write").mockRejectedValue(new Error("disk full"))
    await expect(oldA.conversation.setDraft("Latest accepted unsaved text")).rejects.toThrow(
      "disk full",
    )
    await expect(f.navigation.open(chatB.id, new AbortController().signal)).rejects.toThrow(
      "disk full",
    )
    expect(f.db.fullChatWindows.isActive(chatA.id)).toBe(false)
    expect(f.db.fullChatWindows.isActive(chatB.id)).toBe(false)
    expect(oldA.conversation.getSnapshot().draft).toBe("Latest accepted unsaved text")
    expect(f.db.get(f.db.ref(DbObjectKind.MessageDraft, draftA))?.text).toBe("Saved draft")
    await expect(f.navigation.close()).rejects.toThrow("disk full")
    writes.mockImplementation(durableWrite)
    const openedB = await f.navigation.open(chatB.id, new AbortController().signal)
    expect(f.db.get(f.db.ref(DbObjectKind.MessageDraft, draftA))?.text).toBe(
      "Latest accepted unsaved text",
    )
    expect(f.db.fullChatWindows.isActive(chatA.id)).toBe(false)
    expect(f.db.fullChatWindows.isActive(chatB.id)).toBe(true)
    await f.navigation.close(oldA.conversation)
    expect(f.db.fullChatWindows.isActive(chatB.id)).toBe(true)
    expect(await f.navigation.open(chatB.id, new AbortController().signal)).toBe(openedB)
    const reopenedA = await f.navigation.open(chatA.id, new AbortController().signal)
    expect(reopenedA.conversation.getSnapshot().draft).toBe("Latest accepted unsaved text")
    expect(reopenedA.conversation.getSnapshot().loading).toBe(false)
    expect(reopenedA.conversation).not.toBe(oldA.conversation)
  })

  it("shares a recovery write across racing loaders after cleanup already stopped the pane", async () => {
    const f = await fixture()
    const oldA = await f.navigation.open(chatA.id, new AbortController().signal)
    const durableWrite = f.store.write.bind(f.store)
    const writes = vi.spyOn(f.store, "write").mockRejectedValueOnce(new Error("disk full"))
    await expect(oldA.conversation.setDraft("Recover after cleanup")).rejects.toThrow("disk full")
    await expect(f.navigation.close(oldA.conversation)).rejects.toThrow("disk full")
    const blocked = deferred<void>()
    writes.mockClear().mockImplementationOnce(async (operations) => {
      await blocked.promise
      await durableWrite(operations)
    })
    const first = f.navigation.open(chatB.id, new AbortController().signal)
    const superseded = expect(first).rejects.toMatchObject({ name: "AbortError" })
    const second = f.navigation.open(chatA.id, new AbortController().signal)
    await vi.waitFor(() => expect(writes).toHaveBeenCalledTimes(1))
    expect(f.db.fullChatWindows.isActive(chatA.id)).toBe(false)
    expect(f.db.fullChatWindows.isActive(chatB.id)).toBe(false)
    blocked.resolve()
    await superseded
    const reopenedA = await second
    expect(reopenedA.conversation.getSnapshot().draft).toBe("Recover after cleanup")
    expect(writes).toHaveBeenCalledTimes(1)
    expect(f.db.fullChatWindows.isActive(chatA.id)).toBe(true)
    expect(f.db.fullChatWindows.isActive(chatB.id)).toBe(false)
    await f.navigation.close(oldA.conversation)
    expect(f.db.fullChatWindows.isActive(chatA.id)).toBe(true)
  })

  it.each([false, true])(
    "waits for local send acceptance after retirement and preserves only unconsumed compose (new typing %s)",
    async (newTyping) => {
      const f = await fixture()
      const oldA = await f.navigation.open(chatA.id, new AbortController().signal)
      vi.spyOn(f.store, "write").mockRejectedValueOnce(new Error("disk full"))
      await expect(oldA.conversation.setDraft("Sent once after retirement")).rejects.toThrow(
        "disk full",
      )
      const accepting = deferred<void>()
      f.mutateAccepted.mockImplementationOnce(async (transaction) => {
        await accepting.promise
        await f.db.commit(() => {
          transaction.optimistic?.(f.db, f.auth)
        })
      })
      const send = oldA.conversation.send()
      await vi.waitFor(() => expect(f.mutateAccepted).toHaveBeenCalledTimes(1))
      if (newTyping) {
        vi.spyOn(f.store, "write").mockRejectedValueOnce(new Error("new draft not saved"))
        await expect(oldA.conversation.setDraft("Newer unsaved compose")).rejects.toThrow(
          "new draft not saved",
        )
      }
      const close = f.navigation.close(oldA.conversation)
      const closing = close.then(
        () => undefined,
        (error: unknown) => error,
      )
      let closed = false
      void closing.then(() => {
        closed = true
      })
      await Promise.resolve()
      expect(closed).toBe(false)
      accepting.resolve()
      await send
      const closeError = await closing
      if (newTyping) expect((closeError as Error).message).toContain("new draft not saved")
      else expect(closeError).toBeUndefined()
      const reopenedA = await f.navigation.open(chatA.id, new AbortController().signal)
      expect(reopenedA.conversation.getSnapshot().draft).toBe(
        newTyping ? "Newer unsaved compose" : "",
      )
      expect(
        f.db
          .queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message)
          .filter((message) => message.message === "Sent once after retirement"),
      ).toHaveLength(1)
      expect(f.db.get(f.db.ref(DbObjectKind.MessageDraft, draftA))?.text ?? "").toBe(
        newTyping ? "Newer unsaved compose" : "",
      )
    },
  )
})
