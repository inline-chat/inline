import { ConnectionError_Reason, ServerProtocolMessage } from "@inline-chat/protocol/core"
import { chatId, messageId, userId } from "@inline/ids"
import { IDBFactory, IDBKeyRange } from "fake-indexeddb"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { AuthStore } from "../../auth/auth-store"
import { Db } from "../../database"
import { DbObjectKind, messageKey } from "../../database/models"
import { createIndexedDbPersistenceStore } from "../../database/storage"
import { DbQueryPlanType } from "../../database/types"
import { RealtimeClient } from "../realtime"
import { sendMessage } from "../transactions/send-message"
import { MockTransport } from "../transport/mock-transport"

const actor = userId(7)
const temporaryKey = messageKey(chatId(801), messageId(-500))
const deferred = <T>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((settle) => {
    resolve = settle
  })
  return { promise, resolve }
}

const transaction = () =>
  sendMessage({
    chatId: chatId(801),
    peerId: { type: { oneofKind: "chat", chat: { chatId: 801n } } },
    temporaryMessageId: messageId(-500),
    randomId: 42n,
    text: "Only the bound account may send this",
  })

const fixture = () => {
  const namespace = `account-identity-${crypto.randomUUID()}`
  const store = createIndexedDbPersistenceStore(namespace)
  if (!store) throw new Error("IndexedDB persistence unavailable")
  const db = new Db({ autoHydrate: false, persistenceStore: store })
  const auth = new AuthStore()
  const transport = new MockTransport()
  const client = new RealtimeClient({ auth, db, transport, sync: false, url: "ws://example.test" })
  return { namespace, store, db, auth, transport, client }
}
type Context = ReturnType<typeof fixture>

const rotate = async (auth: AuthStore, target: "different" | "cleared") => {
  if (target === "cleared") await auth.logout()
  else await auth.login({ token: "test-account8-token", userId: userId(8) })
}

const expectNoAcceptance = async (context: Context) => {
  expect(context.db.get(context.db.ref(DbObjectKind.Message, temporaryKey))).toBeUndefined()
  expect(context.db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.PendingTransaction)).toEqual([])
  expect(await context.store.collection(DbObjectKind.Message).get(temporaryKey)).toBeUndefined()
  expect(await context.store.collection(DbObjectKind.PendingTransaction).getAll()).toEqual([])
}

const connect = async (context: Context) => {
  const connected = deferred<void>()
  const unsubscribe = context.client.onConnectionState((state) => {
    if (state === "connected") connected.resolve()
  })
  try {
    await context.client.startSession({ token: "test-account7-token", userId: actor })
    await context.transport.connect()
    await context.transport.emitMessage(
      ServerProtocolMessage.create({
        body: { oneofKind: "connectionOpen", connectionOpen: {} },
      }),
    )
    await connected.promise
  } finally {
    unsubscribe()
  }
}

describe("realtime account admission", () => {
  beforeEach(() => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
  })
  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it.each(["different", "cleared"] as const)("rejects new durable sends after authentication is %s", async (target) => {
    const context = fixture()
    const send = transaction()
    const optimistic = vi.spyOn(send, "optimistic")
    const failed = vi.spyOn(send, "failed")
    const cancelled = vi.spyOn(send, "cancelled")
    try {
      await context.client.startSession({ token: "test-account7-token", userId: actor })
      await rotate(context.auth, target)
      await expect(context.client.mutateAccepted(send)).rejects.toThrow()
      expect(optimistic).not.toHaveBeenCalled()
      expect(failed).not.toHaveBeenCalled()
      expect(cancelled).not.toHaveBeenCalled()
      await expectNoAcceptance(context)
    } finally {
      await context.client.stop()
      await context.db.closePersistence()
    }
  })

  it.each(["different", "cleared"] as const)(
    "rejects a queued durable send when authentication becomes %s before its writer runs",
    async (target) => {
      const context = fixture()
      const writeStarted = deferred<void>()
      const releaseWrite = deferred<void>()
      const write = context.store.write.bind(context.store)
      const blockerId = chatId(899)
      vi.spyOn(context.store, "write").mockImplementation(async (operations) => {
        if (
          operations.some(
            (operation) =>
              operation.type === "put" &&
              operation.object.kind === DbObjectKind.Chat &&
              operation.object.id === blockerId,
          )
        ) {
          writeStarted.resolve()
          await releaseWrite.promise
        }
        await write(operations)
      })
      let blocker: Promise<void> | undefined
      let acceptance: Promise<void> | undefined
      const send = transaction()
      const optimistic = vi.spyOn(send, "optimistic")
      const failed = vi.spyOn(send, "failed")
      const cancelled = vi.spyOn(send, "cancelled")
      try {
        await context.client.startSession({ token: "test-account7-token", userId: actor })
        blocker = context.db.commit(() =>
          context.db.insert({ kind: DbObjectKind.Chat, id: blockerId, title: "Writer gate" }),
        )
        await writeStarted.promise
        acceptance = context.client.mutateAccepted(send)
        const rejected = expect(acceptance).rejects.toThrow()
        await rotate(context.auth, target)
        releaseWrite.resolve()
        await blocker
        await rejected
        expect(optimistic).not.toHaveBeenCalled()
        expect(failed).not.toHaveBeenCalled()
        expect(cancelled).not.toHaveBeenCalled()
        await expectNoAcceptance(context)
        await context.db.closePersistence()
        const restarted = new Db({ autoHydrate: false, storageNamespace: context.namespace })
        try {
          await restarted.hydrateKinds([DbObjectKind.Message, DbObjectKind.PendingTransaction])
          expect(restarted.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message)).toEqual([])
          expect(restarted.queryCollection(DbQueryPlanType.Objects, DbObjectKind.PendingTransaction)).toEqual([])
        } finally {
          await restarted.closePersistence()
        }
      } finally {
        releaseWrite.resolve()
        await blocker
        await acceptance?.catch(() => undefined)
        await context.client.stop()
        await context.db.closePersistence()
      }
    },
  )

  it("binds authenticated starting acceptance before the first asynchronous database wait", async () => {
    const context = fixture()
    const ready = deferred<void>()
    context.db.ready = ready.promise
    let start: Promise<void> | undefined
    try {
      await context.auth.login({ token: "test-account7-token", userId: actor })
      start = context.client.start()
      const rejectedStart = expect(start).rejects.toThrow("Inline realtime belongs to another account")
      await rotate(context.auth, "different")
      await expect(context.client.mutateAccepted(transaction())).rejects.toThrow()
      await expectNoAcceptance(context)
      ready.resolve()
      await rejectedStart
    } finally {
      ready.resolve()
      await start?.catch(() => undefined)
      await context.client.stop()
      await context.db.closePersistence()
    }
  })

  it("refuses durable acceptance during an unauthenticated first start", async () => {
    const context = fixture()
    const ready = deferred<void>()
    context.db.ready = ready.promise
    let start: Promise<void> | undefined
    try {
      start = context.client.start()
      const rejectedStart = expect(start).rejects.toThrow("not-authorized")
      await expect(context.client.mutateAccepted(transaction())).rejects.toThrow()
      await expectNoAcceptance(context)
      ready.resolve()
      await rejectedStart
      expect(context.auth.getToken()).toBeNull()
    } finally {
      ready.resolve()
      await start?.catch(() => undefined)
      await context.client.stop()
      await context.db.closePersistence()
    }
  })

  it.each(["different-before", "same-during", "matching"] as const)(
    "only clears the exact revoked transport credential (%s)",
    async (replacement) => {
      const context = fixture()
      const stopping = deferred<void>()
      const releaseStop = deferred<void>()
      const completed = deferred<void>()
      const stop = context.client.stop.bind(context.client)
      const logout = vi.spyOn(context.auth, "logout")
      const automaticStop = vi.spyOn(context.client, "stop").mockImplementation(async () => {
        stopping.resolve()
        await releaseStop.promise
        await stop()
        completed.resolve()
      })
      try {
        await connect(context)
        if (replacement === "different-before") await rotate(context.auth, "different")
        await context.transport.emitMessage(
          ServerProtocolMessage.create({
            body: { oneofKind: "connectionError", connectionError: { reason: ConnectionError_Reason.SESSION_REVOKED } },
          }),
        )
        await stopping.promise
        if (replacement === "same-during")
          await context.auth.login({ token: "test-account7-fresh-token", userId: actor })
        releaseStop.resolve()
        await completed.promise
        await vi.waitFor(() => expect(context.client.connection.state).toBe("stopped"))
        // Let the automatic revocation continuation compare credentials after its stop await.
        await Promise.resolve()
        await Promise.resolve()
        if (replacement === "matching") {
          await vi.waitFor(() => expect(context.auth.isLoggedIn()).toBe(false))
          expect(logout).toHaveBeenCalledOnce()
        } else {
          expect(context.auth.getToken()).toBe(
            replacement === "same-during" ? "test-account7-fresh-token" : "test-account8-token",
          )
          expect(context.auth.getState().currentUserId).toBe(replacement === "same-during" ? actor : userId(8))
          expect(logout).not.toHaveBeenCalled()
        }
      } finally {
        releaseStop.resolve()
        automaticStop.mockRestore()
        await context.client.stop()
        await context.db.closePersistence()
      }
    },
  )
})
