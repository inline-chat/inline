import { AuthStore } from "@inline/auth/core"
import {
  DbObjectKind,
  DbQueryPlanType,
  MessageSendingStatus,
  messageKey,
  sendMessage,
  type Message,
  type PendingTransaction,
} from "@inline/client/core"
import { chatId, dialogId, messageId, userId } from "@inline/ids"
import { ConnectionError_Reason, GetChatsResult, Method, ServerProtocolMessage, type RpcResult } from "@inline-chat/protocol/core"
import { MockTransport } from "@inline/client/realtime/transport/mock-transport"
import { IDBFactory, IDBKeyRange } from "fake-indexeddb"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { Account, accountStorageNamespace } from "./account"
import { accountWriterName } from "./account-writer"
import { Conversation } from "../conversation/Conversation"

const deferred = () => {
  let resolve!: () => void
  const promise = new Promise<void>((done) => { resolve = done })
  return { promise, resolve }
}

/** FIFO browser-lock stand-in. Cache reads/writes below use real IndexedDB. */
class BrowserLocks {
  readonly held = new Set<string>()
  private readonly queues = new Map<string, Array<() => void>>()

  request<T>(name: string, options: LockOptions, callback: (lock: Lock) => Promise<T>) {
    return new Promise<T>((resolve, reject) => {
      const signal = options.signal
      const queue = this.queues.get(name) ?? []
      this.queues.set(name, queue)
      const abort = () => {
        const index = queue.indexOf(acquire)
        if (index >= 0) queue.splice(index, 1)
        reject(signal?.reason)
      }
      const acquire = () => {
        signal?.removeEventListener("abort", abort)
        this.held.add(name)
        void callback({ name, mode: "exclusive" }).then(resolve, reject).finally(() => {
          this.held.delete(name)
          queue.shift()?.()
        })
      }
      if (signal?.aborted) { reject(signal.reason); return }
      signal?.addEventListener("abort", abort, { once: true })
      if (this.held.has(name)) queue.push(acquire)
      else acquire()
    })
  }
}

const until = async (condition: () => boolean) => {
  await vi.waitFor(() => { expect(condition()).toBe(true) }, { timeout: 2_000, interval: 5 })
}

describe("web account ownership and durable isolation", () => {
  let locks: BrowserLocks
  let factory: IDBFactory
  let accounts: Account[]
  let authStores: AuthStore[]

  beforeEach(() => {
    locks = new BrowserLocks()
    factory = new IDBFactory()
    accounts = []
    authStores = []
    vi.stubGlobal("indexedDB", factory)
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
    vi.stubGlobal("navigator", { locks, onLine: false })
  })

  afterEach(async () => {
    // Cancelling all queued owners first avoids cleanup waiting behind a holder.
    await Promise.allSettled(accounts.map((account) => account.stop()))
    for (const auth of authStores) auth.dispose()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  const account = async (id = userId(7), serverUrl = "https://api.inline.test", transport?: MockTransport) => {
    const auth = new AuthStore({ persistence: "memory" })
    authStores.push(auth)
    await auth.ready
    await auth.login({ userId: id, token: "test-session" })
    const owner = new Account(id, { auth, serverUrl, observeBrowserLifecycle: false, transport })
    accounts.push(owner)
    await owner.realtime.connection.setNetworkAvailable(false)
    return owner
  }

  it("hands a committed cache to a queued tab before that tab publishes ready", async () => {
    const first = await account()
    await first.start()
    await first.db.commit(() => {
      first.db.insert({ kind: DbObjectKind.User, id: userId(7), firstName: "Saved name" })
      first.db.insert({ kind: DbObjectKind.Chat, id: chatId(10), title: "Saved chat", lastMsgId: messageId(12) })
      first.db.insert({
        kind: DbObjectKind.Message, id: messageKey(chatId(10), messageId(12)),
        chatId: chatId(10), messageId: messageId(12), fromId: userId(7), message: "Saved preview",
      })
    })
    const second = await account()
    let firstReadyName: string | undefined
    let firstReadyPreview: string | undefined
    second.subscribe(() => {
      if (second.getSnapshot().phase !== "ready") return
      firstReadyName ??= second.db.get(second.db.ref(DbObjectKind.User, userId(7)))?.firstName
      firstReadyPreview ??= second.db.get(second.db.ref(DbObjectKind.Message, messageKey(chatId(10), messageId(12))))?.message
    })
    const starting = second.start()
    await until(() => second.getSnapshot().phase === "waiting")
    expect(second.db.get(second.db.ref(DbObjectKind.User, userId(7)))).toBeUndefined()
    expect(locks.held.has(accountWriterName(userId(7)))).toBe(true)
    await first.stop()
    await starting
    expect(firstReadyName).toBe("Saved name")
    expect(firstReadyPreview).toBe("Saved preview")
    expect(second.getSnapshot().phase).toBe("ready")
  })

  it("cancels a queued writer when the waiting tab leaves", async () => {
    const first = await account()
    await first.start()
    const waiting = await account()
    const starting = waiting.start()
    await until(() => waiting.getSnapshot().phase === "waiting")
    await waiting.stop()
    await starting
    await first.stop()
    const next = await account()
    await next.start()
    expect(next.getSnapshot().phase).toBe("ready")
    expect(waiting.getSnapshot().phase).toBe("loading")
  })

  it("holds the writer until realtime drains and IndexedDB closes", async () => {
    const first = await account()
    await first.start()
    const second = await account()
    const starting = second.start()
    await until(() => second.getSnapshot().phase === "waiting")
    const realtimeGate = deferred()
    const persistenceGate = deferred()
    const stopRealtime = first.realtime.stop.bind(first.realtime)
    const closePersistence = first.db.closePersistence.bind(first.db)
    const stop = vi.spyOn(first.realtime, "stop").mockImplementation(async () => {
      await realtimeGate.promise
      await stopRealtime()
    })
    const close = vi.spyOn(first.db, "closePersistence").mockImplementation(async () => {
      await persistenceGate.promise
      await closePersistence()
    })
    const stopping = first.stop()
    await until(() => stop.mock.calls.length === 1)
    expect(close).not.toHaveBeenCalled()
    expect(second.getSnapshot().phase).toBe("waiting")
    realtimeGate.resolve()
    await until(() => close.mock.calls.length === 1)
    expect(second.getSnapshot().phase).toBe("waiting")
    persistenceGate.resolve()
    await stopping
    await starting
    expect(second.getSnapshot().phase).toBe("ready")
  })

  it("disposes the active view's resident window before closing persistence", async () => {
    const first = await account()
    await first.start()
    await first.db.commit(() => {
      first.db.insert({ kind: DbObjectKind.Chat, id: chatId(10), title: "Visible chat" })
      first.db.insert({ kind: DbObjectKind.Message, id: messageKey(chatId(10), messageId(12)), chatId: chatId(10), messageId: messageId(12), fromId: userId(7), message: "Visible message" })
    })
    first.db.activateResidentMessageWindow(chatId(10))
    await first.db.hydrateMessageWindow(chatId(10), { limit: 60 })
    const cleanup = vi.fn(() => { first.db.releaseResidentMessageWindow(chatId(10)) })
    const detach = first.attachViewCleanup(cleanup)
    const closePersistence = first.db.closePersistence.bind(first.db)
    vi.spyOn(first.db, "closePersistence").mockImplementation(async () => {
      expect(cleanup).toHaveBeenCalledTimes(1)
      expect(first.db.fullChatWindows.isActive(chatId(10))).toBe(false)
      await closePersistence()
    })
    await first.stop()
    detach()
    expect(cleanup).toHaveBeenCalledTimes(1)
    expect(locks.held.has(accountWriterName(userId(7)))).toBe(false)
  })

  it("awaits the retired view's queued draft write before closing persistence", async () => {
    const first = await account()
    await first.start()
    const gate = deferred()
    let retired = false
    first.attachViewCleanup(() => {
      retired = true
      return gate.promise.then(() => first.db.commit(() => {
        first.db.insert({ kind: DbObjectKind.MessageDraft, id: `chat:${chatId(10)}`, peerKind: "chat", peerThreadId: chatId(10), text: "Last queued draft", revision: 1, updatedAt: 1 })
      }))
    })
    const close = vi.spyOn(first.db, "closePersistence")
    const stopping = first.stop()
    expect(retired).toBe(true)
    await Promise.resolve()
    expect(close).not.toHaveBeenCalled()
    gate.resolve()
    await stopping
    const reopened = await account()
    await reopened.start()
    await reopened.db.hydrateObjects(DbObjectKind.MessageDraft, [`chat:${chatId(10)}`])
    expect(reopened.db.get(reopened.db.ref(DbObjectKind.MessageDraft, `chat:${chatId(10)}`))?.text).toBe("Last queued draft")
  })

  it("surfaces a failed view drain and retains the writer instead of admitting another owner", async () => {
    const first = await account()
    await first.start()
    first.attachViewCleanup(() => Promise.reject(new Error("draft write failed")))
    await expect(first.stop()).rejects.toThrow("could not safely close")
    expect(first.getSnapshot().phase).toBe("error")
    expect(locks.held.has(accountWriterName(userId(7)))).toBe(true)
  })

  it("retains a detached Conversation's queued draft tail until parent account stop completes", async () => {
    const first = await account()
    await first.start()
    const chat = { kind: DbObjectKind.Chat as const, id: chatId(10), title: "Draft owner" }
    await first.db.commit(() => { first.db.insert(chat) })
    const conversation = new Conversation(first.db, first.realtime, chat)
    await conversation.start()
    const gate = deferred()
    const commit = first.db.commit.bind(first.db)
    vi.spyOn(first.db, "commit").mockImplementationOnce(async (recipe) => {
      await gate.promise
      await commit(recipe)
    })
    const firstWrite = conversation.setDraft("First queued draft")
    const lastWrite = conversation.setDraft("Final queued draft")
    const detach = first.attachViewCleanup(() => {
      conversation.stop()
      return conversation.drain()
    })
    // React can delete the child subtree before the parent's account effect.
    detach()
    expect(first.db.fullChatWindows.isActive(chat.id)).toBe(false)
    const close = vi.spyOn(first.db, "closePersistence")
    const stopping = first.stop()
    await Promise.resolve()
    expect(close).not.toHaveBeenCalled()
    expect(locks.held.has(accountWriterName(userId(7)))).toBe(true)
    gate.resolve()
    await Promise.all([firstWrite, lastWrite, stopping])
    const reopened = await account()
    await reopened.start()
    await reopened.db.hydrateObjects(DbObjectKind.MessageDraft, [`chat:${chat.id}`])
    expect(reopened.db.get(reopened.db.ref(DbObjectKind.MessageDraft, `chat:${chat.id}`))?.text).toBe("Final queued draft")
  })

  it("retains a detached view-drain rejection and keeps the account writer on stop failure", async () => {
    const first = await account()
    await first.start()
    const detach = first.attachViewCleanup(() => Promise.reject(new Error("detached draft tail failed")))
    detach()
    await expect(first.stop()).rejects.toThrow("could not safely close")
    expect(first.getSnapshot().phase).toBe("error")
    expect(locks.held.has(accountWriterName(userId(7)))).toBe(true)
  })

  it("does not let a stale detach retire a replacement attachment that reuses the callback", async () => {
    const first = await account()
    await first.start()
    const cleanup = vi.fn(() => {})
    const detachOld = first.attachViewCleanup(cleanup)
    detachOld()
    expect(cleanup).toHaveBeenCalledTimes(1)
    const detachNew = first.attachViewCleanup(cleanup)
    detachOld()
    expect(cleanup).toHaveBeenCalledTimes(1)
    detachNew()
    expect(cleanup).toHaveBeenCalledTimes(2)
    await first.stop()
  })

  it("retains the writer after a failed persistence close", async () => {
    const first = await account()
    await first.start()
    vi.spyOn(first.db, "closePersistence").mockRejectedValue(new Error("storage close failed"))
    await expect(first.stop()).rejects.toThrow("could not safely close")
    const second = await account()
    const starting = second.start()
    await until(() => second.getSnapshot().phase === "waiting")
    expect(locks.held.has(accountWriterName(userId(7)))).toBe(true)
    expect(first.getSnapshot().phase).toBe("error")
    await expect(first.start()).rejects.toThrow("could not safely close")
    await second.stop()
    await starting
  })

  it("retains the writer when realtime cannot drain even if persistence closes", async () => {
    const first = await account()
    await first.start()
    vi.spyOn(first.realtime, "stop").mockRejectedValue(new Error("realtime drain failed"))
    await expect(first.stop()).rejects.toThrow("could not safely close")
    const second = await account()
    const starting = second.start()
    await until(() => second.getSnapshot().phase === "waiting")
    expect(locks.held.has(accountWriterName(userId(7)))).toBe(true)
    await second.stop()
    await starting
  })

  it("restores an accepted offline send without changing its idempotency key", async () => {
    const first = await account()
    await first.start()
    await first.db.commit(() => {
      first.db.insert({ kind: DbObjectKind.Chat, id: chatId(10), title: "Offline" })
    })
    const transaction = sendMessage({
      chatId: chatId(10), text: "Survives closing the tab",
      peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
    })
    await first.realtime.mutateAccepted(transaction)
    const temporaryId = transaction.context.temporaryMessageId!
    const randomId = transaction.context.randomId
    await first.stop()
    const reopened = await account()
    await reopened.start()
    const restored = reopened.db.get(reopened.db.ref(DbObjectKind.Message, messageKey(chatId(10), temporaryId)))
    expect(restored?.message).toBe("Survives closing the tab")
    expect(restored?.randomId).toBe(randomId)
    expect(restored?.status).toBe(MessageSendingStatus.Sending)
    const outbox = reopened.db.queryCollection<DbObjectKind.PendingTransaction, PendingTransaction, DbQueryPlanType.Objects>(
      DbQueryPlanType.Objects, DbObjectKind.PendingTransaction,
    )
    expect(outbox).toHaveLength(1)
    expect((outbox[0]!.context as typeof transaction.context).randomId).toBe(randomId)
  })

  it("isolates account and server caches while retaining the shared account writer name", async () => {
    const first = await account()
    await first.start()
    await first.db.commit(() => {
      first.db.insert({ kind: DbObjectKind.User, id: userId(7), firstName: "Private cached data" })
    })
    await first.stop()
    const anotherAccount = await account(userId(8))
    await anotherAccount.start()
    expect(anotherAccount.db.queryCollection<DbObjectKind.Message, Message, DbQueryPlanType.Objects>(
      DbQueryPlanType.Objects, DbObjectKind.Message,
    )).toEqual([])
    expect(anotherAccount.db.get(anotherAccount.db.ref(DbObjectKind.User, userId(7)))).toBeUndefined()
    const anotherServer = await account(userId(7), "https://other.inline.test")
    await anotherServer.start()
    expect(anotherServer.db.get(anotherServer.db.ref(DbObjectKind.User, userId(7)))).toBeUndefined()
    expect((await factory.databases()).map((database) => database.name)).toHaveLength(3)
    expect(accountStorageNamespace(userId(7), "https://api.inline.test/")).toBe(accountStorageNamespace(userId(7), "https://api.inline.test"))
    expect(accountWriterName(userId(7))).toBe("inline-core-account-7")
  })

  it("rejects an account/token identity mismatch before opening its cache", async () => {
    const first = await account()
    await first.auth.login({ userId: userId(8), token: "other-account-session" })
    await expect(first.start()).rejects.toThrow("session does not match")
    expect(await factory.databases()).toEqual([])
    expect(locks.held.size).toBe(0)
  })

  it("stops the old writer when auth switches account", async () => {
    const first = await account()
    await first.start()
    await first.auth.login({ userId: userId(8), token: "other-account-session" })
    await until(() => !locks.held.has(accountWriterName(userId(7))))
    expect(first.realtime.connection.constraints.userWantsConnection).toBe(false)
  })

  it("retires a writer on same-user token replacement before the new owner opens", async () => {
    const first = await account()
    await first.start()
    await first.db.commit(() => {
      first.db.insert({ kind: DbObjectKind.Chat, id: chatId(10), title: "Retained account data" })
    })
    await first.auth.login({ userId: userId(7), token: "replacement-session" })
    await until(() => !locks.held.has(accountWriterName(userId(7))))
    expect(first.realtime.connection.constraints.userWantsConnection).toBe(false)
    const next = new Account(userId(7), { auth: first.auth, serverUrl: "https://api.inline.test", observeBrowserLifecycle: false })
    accounts.push(next)
    await next.realtime.connection.setNetworkAvailable(false)
    await next.start()
    expect(next.auth.getToken()).toBe("replacement-session")
    expect(next.db.get(next.db.ref(DbObjectKind.Chat, chatId(10)))?.title).toBe("Retained account data")
    await expect(first.start()).rejects.toThrow("new Inline account owner")
  })

  it("cancels a queued acquisition immediately if its auth switches account", async () => {
    const first = await account()
    await first.start()
    const waiting = await account()
    const starting = waiting.start()
    await until(() => waiting.getSnapshot().phase === "waiting")
    await waiting.auth.login({ userId: userId(8), token: "other-account-session" })
    await starting
    await waiting.stop()
    expect(waiting.getSnapshot().phase).toBe("loading")
    await first.stop()
    expect(locks.held.size).toBe(0)
  })

  it("permits an interrupted initial effect to start again but retires a released writer", async () => {
    const first = await account()
    const initialStart = first.start()
    await first.stop()
    await initialStart
    await first.start()
    expect(first.getSnapshot().phase).toBe("ready")
    await first.stop()
    await expect(first.start()).rejects.toThrow("new Inline account owner")
  })

  it("fails closed without browser ownership or durable storage", async () => {
    const noLocks = await account()
    vi.stubGlobal("navigator", { onLine: false })
    await expect(noLocks.start()).rejects.toThrow("requires browser Web Locks")
    expect(await factory.databases()).toEqual([])
    vi.stubGlobal("navigator", { locks, onLine: false })
    vi.stubGlobal("indexedDB", undefined)
    const noStorage = await account()
    await expect(noStorage.start()).rejects.toThrow("requires IndexedDB")
    expect(locks.held.size).toBe(0)
  })

  it("surfaces INVALID_AUTH while preserving cache/session and retries durable sending on the same owner", async () => {
    const transport = new MockTransport()
    const first = await account(userId(7), "https://api.inline.test", transport)
    await first.realtime.connection.setNetworkAvailable(true)
    await first.start()
    expect(first.getSnapshot().authUnavailable).toBe(false)
    await first.db.commit(() => {
      first.db.insert({ kind: DbObjectKind.Chat, id: chatId(10), title: "Preserved chat" })
    })
    const logout = vi.spyOn(first.auth, "logout")
    await transport.connect()
    await transport.emitMessage(ServerProtocolMessage.create({
      body: { oneofKind: "connectionError", connectionError: { reason: ConnectionError_Reason.INVALID_AUTH } },
    }))
    await until(() => first.getSnapshot().authUnavailable === true)
    expect(first.getSnapshot()).toMatchObject({ phase: "ready", connectionState: "idle" })
    expect(logout).not.toHaveBeenCalled()
    expect(first.auth.getToken()).toBe("test-session")
    expect(first.db.get(first.db.ref(DbObjectKind.Chat, chatId(10)))?.title).toBe("Preserved chat")
    await expect(first.realtime.mutateAccepted(sendMessage({ chatId: chatId(10), text: "Cannot accept while stopped" }))).rejects.toBeDefined()
    // Recovery restores the realtime owner even offline, so sends can once
    // again be accepted durably while awaiting an authenticated connection.
    await first.realtime.connection.setNetworkAvailable(false)
    await first.retry()
    expect(first.getSnapshot().authUnavailable).toBe(false)
    await first.realtime.mutateAccepted(sendMessage({
      chatId: chatId(10), text: "Accepted after recovery",
      peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
    }))
    expect(first.db.queryCollection<DbObjectKind.PendingTransaction, PendingTransaction, DbQueryPlanType.Objects>(
      DbQueryPlanType.Objects, DbObjectKind.PendingTransaction,
    )).toHaveLength(1)
    expect(locks.held.has(accountWriterName(userId(7)))).toBe(true)
    expect(first.auth.getToken()).toBe("test-session")
  })

  it("serializes getMe before chat-list refresh and bounds overlapping invalidations to one reschedule", async () => {
    const transport = new MockTransport()
    const first = await account(userId(7), "https://api.inline.test", transport)
    await first.realtime.connection.setNetworkAvailable(true)
    await first.start()
    await first.db.commit(() => {
      first.db.insert({ kind: DbObjectKind.Chat, id: chatId(10), title: "Current chat" })
      first.db.insert({ kind: DbObjectKind.Dialog, id: dialogId(10), chatId: chatId(10), peerThreadId: chatId(10), readMaxId: messageId(12), unreadCount: 4 })
    })
    const requests = (method: Method) => transport.sent.filter((frame) => frame.body.oneofKind === "rpcCall" && frame.body.rpcCall.method === method)
    const reply = async (method: Method, index: number, result: RpcResult["result"]) => {
      const request = requests(method)[index]!
      await transport.emitMessage(ServerProtocolMessage.create({
        body: { oneofKind: "rpcResult", rpcResult: { reqMsgId: request.id, result } },
      }))
    }
    const getMeResult: RpcResult["result"] = { oneofKind: "getMe", getMe: { user: { id: 7n, firstName: "Saved user" } } }
    const staleResult: RpcResult["result"] = {
      oneofKind: "getChats", getChats: GetChatsResult.create({
        chats: [{ id: 10n, title: "Stale chat" }],
        dialogs: [{ chatId: 10n, peer: { type: { oneofKind: "chat", chat: { chatId: 10n } } }, readMaxId: 12n, unreadCount: 4 }],
      }),
    }
    await transport.connect()
    await transport.emitMessage(ServerProtocolMessage.create({ body: { oneofKind: "connectionOpen", connectionOpen: {} } }))
    await until(() => requests(Method.GET_ME).length === 1)
    expect(requests(Method.GET_CHATS)).toHaveLength(0)
    await reply(Method.GET_ME, 0, getMeResult)
    await until(() => requests(Method.GET_CHATS).length === 1)
    const retrying = first.retry()
    await first.db.commit(() => {
      first.db.update({ ...first.db.get(first.db.ref(DbObjectKind.Dialog, dialogId(10)))!, readMaxId: messageId(20), unreadCount: 0 })
    })
    await reply(Method.GET_CHATS, 0, staleResult)
    await until(() => requests(Method.GET_ME).length === 2)
    expect(requests(Method.GET_CHATS)).toHaveLength(1)
    expect(first.db.get(first.db.ref(DbObjectKind.Dialog, dialogId(10)))).toMatchObject({ readMaxId: messageId(20), unreadCount: 0 })
    await reply(Method.GET_ME, 1, getMeResult)
    await until(() => requests(Method.GET_CHATS).length === 2)
    await first.db.commit(() => {
      first.db.update({ ...first.db.get(first.db.ref(DbObjectKind.Dialog, dialogId(10)))!, readMaxId: messageId(21), unreadCount: 0 })
    })
    await reply(Method.GET_CHATS, 1, staleResult)
    await retrying
    expect(requests(Method.GET_ME)).toHaveLength(2)
    expect(requests(Method.GET_CHATS)).toHaveLength(2)
    expect(first.db.get(first.db.ref(DbObjectKind.Dialog, dialogId(10)))).toMatchObject({ readMaxId: messageId(21), unreadCount: 0 })
    expect(first.db.get(first.db.ref(DbObjectKind.Chat, chatId(10)))?.title).toBe("Current chat")
    expect(first.getSnapshot().error).toContain("Chats changed during refresh")
  })

  it("stops and releases ownership while a manual retry waits for an unanswered refresh", async () => {
    const transport = new MockTransport()
    const first = await account(userId(7), "https://api.inline.test", transport)
    await first.realtime.connection.setNetworkAvailable(true)
    await first.start()
    await transport.connect()
    await transport.emitMessage(ServerProtocolMessage.create({ body: { oneofKind: "connectionOpen", connectionOpen: {} } }))
    await until(() => transport.sent.some((frame) => frame.body.oneofKind === "rpcCall" && frame.body.rpcCall.method === Method.GET_ME))
    const retrying = first.retry()
    await Promise.resolve()
    await first.stop()
    await retrying
    expect(locks.held.has(accountWriterName(userId(7)))).toBe(false)
    expect(first.realtime.connection.constraints.userWantsConnection).toBe(false)
  })
})
