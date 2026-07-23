import {
  Method,
  RpcError_Code,
  ServerProtocolMessage,
  Update,
  type ClientMessage,
  type InputPeer,
} from "@inline-chat/protocol/core"
import {
  IDBFactory,
  IDBKeyRange,
  IDBObjectStore,
} from "fake-indexeddb"
import { chatId, dialogId, messageId, userId } from "@inline/ids"
import {
  afterEach,
  describe,
  expect,
  it,
  vi,
} from "vitest"
import { AuthStore } from "../../auth"
import { Db } from "../../database"
import {
  DbObjectKind,
  MessageSendingStatus,
  messageKey,
  type Message,
  type PendingTransaction,
} from "../../database/models"
import type { CollectionStorage } from "../../database/storage"
import { DbQueryPlanType } from "../../database/types"
import { RealtimeClient } from "../realtime"
import {
  pinMessage,
  sendMessage,
  updateDialogOpen,
} from "../transactions"
import { MockTransport } from "../transport/mock-transport"

const waitFor = async (predicate: () => boolean, timeoutMs = 500) => {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  throw new Error("Timed out waiting for condition")
}

const connectAndOpen = async (transport: MockTransport) => {
  await transport.connect()
  await transport.emitMessage(
    ServerProtocolMessage.create({
      id: 1n,
      body: { oneofKind: "connectionOpen", connectionOpen: {} },
    }),
  )
}

const peerId: InputPeer = {
  type: {
    oneofKind: "chat",
    chat: { chatId: 10n },
  },
}

const rpcCall = (message: ClientMessage) =>
  message.body.oneofKind === "rpcCall" &&
  message.body.rpcCall.method === Method.SEND_MESSAGE

describe("durable transaction outbox", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("rolls the optimistic message back when the outbox cannot persist", async () => {
    const auth = new AuthStore()
    auth.login({ token: "token", userId: userId(7) })
    const db = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.PendingTransaction]: {
          init: async () => {},
          get: async () => undefined,
          getAll: async () => [],
          put: async () => {
            throw new Error("disk full")
          },
          delete: async () => {},
        },
      },
    })
    const client = new RealtimeClient({
      auth,
      db,
      transport: new MockTransport(),
      sync: false,
    })

    await expect(
      client.execute(
        sendMessage({
          chatId: chatId(10),
          peerId,
          text: "Must not become a phantom",
        }),
      ),
    ).rejects.toBeDefined()

    expect(
      db.queryCollection<
        DbObjectKind.Message,
        Message,
        DbQueryPlanType.Objects
      >(
        DbQueryPlanType.Objects,
        DbObjectKind.Message,
      ),
    ).toEqual([])
    expect(
      db.queryCollection<
        DbObjectKind.PendingTransaction,
        PendingTransaction,
        DbQueryPlanType.Objects
      >(
        DbQueryPlanType.Objects,
        DbObjectKind.PendingTransaction,
      ),
    ).toEqual([])
  })

  it("captures dialog rollback state before persisting its optimistic outbox", async () => {
    const auth = new AuthStore()
    const db = new Db({ autoHydrate: false, persistence: false })
    db.insert({
      kind: DbObjectKind.Dialog,
      id: dialogId(-10),
      chatId: chatId(10),
      peerThreadId: chatId(10),
      open: true,
      order: "a0",
      archived: false,
    })
    const client = new RealtimeClient({
      auth,
      db,
      transport: new MockTransport(),
      sync: false,
    })
    await client.startSession({ token: "token", userId: userId(7) })

    const result = client.execute(
      updateDialogOpen({ peerId, open: false }),
    )
    await waitFor(
      () =>
        db.queryCollection(
          DbQueryPlanType.Objects,
          DbObjectKind.PendingTransaction,
        ).length === 1,
    )
    const [record] = db.queryCollection<
      DbObjectKind.PendingTransaction,
      PendingTransaction,
      DbQueryPlanType.Objects
    >(
      DbQueryPlanType.Objects,
      DbObjectKind.PendingTransaction,
    )
    expect(record?.context).toMatchObject({
      open: false,
      previousState: {
        open: true,
        order: "a0",
        archived: false,
      },
    })
    expect(
      db.get(db.ref(DbObjectKind.Dialog, dialogId(-10))),
    ).toMatchObject({ open: false, order: undefined })

    await client.stop()
    await Promise.allSettled([result])
  })

  it("persists exact Unpin state in the same optimistic execution boundary", async () => {
    const auth = new AuthStore()
    const db = new Db({ autoHydrate: false, persistence: false })
    db.insert({
      kind: DbObjectKind.Chat,
      id: chatId(10),
      pinnedMessageIds: [messageId(30), messageId(20)],
    })
    const client = new RealtimeClient({
      auth,
      db,
      transport: new MockTransport(),
      sync: false,
    })
    await client.startSession({ token: "token", userId: userId(7) })

    const result = client.execute(
      pinMessage({
        peerId,
        messageId: messageId(30),
        unpin: true,
      }),
    )
    await waitFor(
      () =>
        db.queryCollection(
          DbQueryPlanType.Objects,
          DbObjectKind.PendingTransaction,
        ).length === 1,
    )

    const [record] = db.queryCollection<
      DbObjectKind.PendingTransaction,
      PendingTransaction,
      DbQueryPlanType.Objects
    >(
      DbQueryPlanType.Objects,
      DbObjectKind.PendingTransaction,
    )
    expect(record).toMatchObject({
      type: "pin_message",
      replayPolicy: "idempotent",
      context: {
        messageId: messageId(30),
        unpin: true,
        previousPinnedMessageIds: [messageId(30), messageId(20)],
        optimisticPinnedMessageIds: [messageId(20)],
      },
    })
    expect(
      db.get(db.ref(DbObjectKind.Chat, chatId(10)))?.pinnedMessageIds,
    ).toEqual([messageId(20)])

    await client.stop()
    await Promise.allSettled([result])
  })

  it("restores persisted dialog rollback state after restart", async () => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
    const namespace = `dialog-close-${crypto.randomUUID()}`
    const firstDb = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    await firstDb.commit(() => {
      firstDb.insert({
        kind: DbObjectKind.Dialog,
        id: dialogId(-10),
        chatId: chatId(10),
        peerThreadId: chatId(10),
        open: true,
        order: "a0",
        archived: false,
      })
    })
    const firstClient = new RealtimeClient({
      auth: new AuthStore(),
      db: firstDb,
      transport: new MockTransport(),
      sync: false,
    })
    await firstClient.startSession({ token: "token", userId: userId(7) })
    const firstResult = firstClient.execute(
      updateDialogOpen({ peerId, open: false }),
    )
    await waitFor(
      () =>
        firstDb.get(
          firstDb.ref(DbObjectKind.Dialog, dialogId(-10)),
        )?.open === false,
    )
    await firstClient.stop()
    await Promise.allSettled([firstResult])

    const secondDb = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    await secondDb.hydrateKinds([DbObjectKind.Dialog])
    const secondTransport = new MockTransport()
    const secondClient = new RealtimeClient({
      auth: new AuthStore(),
      db: secondDb,
      transport: secondTransport,
      sync: false,
    })
    await secondClient.startSession({ token: "token", userId: userId(7) })
    await connectAndOpen(secondTransport)
    await waitFor(
      () =>
        secondTransport.sent.some(
          (message) =>
            message.body.oneofKind === "rpcCall" &&
            message.body.rpcCall.method === Method.UPDATE_DIALOG_OPEN,
        ),
    )
    const request = secondTransport.sent.find(
      (message) =>
        message.body.oneofKind === "rpcCall" &&
        message.body.rpcCall.method === Method.UPDATE_DIALOG_OPEN,
    )
    if (!request) throw new Error("Missing restored dialog close request")
    await secondTransport.emitMessage(
      ServerProtocolMessage.create({
        id: 4n,
        body: {
          oneofKind: "rpcError",
          rpcError: {
            reqMsgId: request.id,
            code: 400,
            errorCode: RpcError_Code.BAD_REQUEST,
            message: "CLOSE_FAILED",
          },
        },
      }),
    )
    await waitFor(
      () =>
        secondDb.get(
          secondDb.ref(DbObjectKind.Dialog, dialogId(-10)),
        )?.open === true,
    )
    expect(
      secondDb.get(
        secondDb.ref(DbObjectKind.Dialog, dialogId(-10)),
      ),
    ).toMatchObject({ open: true, order: "a0", archived: false })
    expect(
      secondDb.queryCollection<
        DbObjectKind.PendingTransaction,
        PendingTransaction,
        DbQueryPlanType.Objects
      >(
        DbQueryPlanType.Objects,
        DbObjectKind.PendingTransaction,
      ),
    ).toMatchObject([{ status: "failed" }])
    await secondClient.stop()
  })

  it("restores and sends a pending message after a client restart", async () => {
    const rows = new Map<string, PendingTransaction>()
    const storage: CollectionStorage<PendingTransaction> = {
      init: async () => {},
      get: async (id) => rows.get(id),
      getAll: async () => Array.from(rows.values()),
      put: async (record) => {
        rows.set(record.id, record)
      },
      delete: async (id) => {
        rows.delete(id)
      },
    }

    const firstDb = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.PendingTransaction]: storage,
      },
    })
    const firstTransport = new MockTransport()
    const firstClient = new RealtimeClient({
      auth: new AuthStore(),
      db: firstDb,
      transport: firstTransport,
      sync: false,
    })
    await firstClient.startSession({ token: "token", userId: userId(7) })

    const firstResult = firstClient.execute(
      sendMessage({
        chatId: chatId(10),
        peerId,
        text: "Survives restart",
      }),
    )
    await waitFor(() => rows.size === 1)
    expect(Array.from(rows.values())[0]).toMatchObject({
      type: "send_message",
      replayPolicy: "idempotent",
      status: "pending",
    })

    await firstClient.stop()
    await Promise.allSettled([firstResult])
    expect(rows.size).toBe(1)

    const secondDb = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.PendingTransaction]: storage,
      },
    })
    const secondTransport = new MockTransport()
    const secondClient = new RealtimeClient({
      auth: new AuthStore(),
      db: secondDb,
      transport: secondTransport,
      sync: false,
    })
    await secondClient.startSession({ token: "token", userId: userId(7) })
    await connectAndOpen(secondTransport)
    await waitFor(() => secondTransport.sent.some(rpcCall))

    const request = secondTransport.sent.find(rpcCall)
    if (
      !request ||
      request.body.oneofKind !== "rpcCall" ||
      request.body.rpcCall.input.oneofKind !== "sendMessage"
    ) {
      throw new Error("Missing restored sendMessage request")
    }
    const randomId = request.body.rpcCall.input.sendMessage.randomId
    if (randomId == null) throw new Error("Missing durable random ID")
    const update = Update.create({
      update: {
        oneofKind: "updateMessageId",
        updateMessageId: {
          messageId: 900n,
          randomId,
        },
      },
    })

    await secondTransport.emitMessage(
      ServerProtocolMessage.create({
        id: 2n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: request.id,
            result: {
              oneofKind: "sendMessage",
              sendMessage: { updates: [update] },
            },
          },
        },
      }),
    )

    await waitFor(() => rows.size === 0)
    expect(
      secondDb.get(
        secondDb.ref(
          DbObjectKind.Message,
          messageKey(chatId(10), messageId(900)),
        ),
      ),
    ).toMatchObject({
      message: "Survives restart",
      status: "sent",
    })
    await secondClient.stop()
  })

  it("settles a retained result locally after a temporary persistence abort", async () => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
    const namespace = `outbox-result-${crypto.randomUUID()}`
    const auth = new AuthStore()
    const db = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    const transport = new MockTransport()
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      sync: false,
    })
    await client.startSession({
      token: "token",
      userId: userId(7),
    })

    const result = client.execute(
      sendMessage({
        chatId: chatId(10),
        peerId,
        text: "Keep until committed",
      }),
    )
    await waitFor(
      () =>
        db.queryCollection(
          DbQueryPlanType.Objects,
          DbObjectKind.PendingTransaction,
        ).length === 1,
    )
    const [optimistic] = db.queryCollection<
      DbObjectKind.Message,
      Message,
      DbQueryPlanType.Objects
    >(
      DbQueryPlanType.Objects,
      DbObjectKind.Message,
    )
    expect(optimistic).toBeDefined()

    await connectAndOpen(transport)
    await waitFor(() => transport.sent.some(rpcCall))
    const request = transport.sent.find(rpcCall)
    if (
      !request ||
      request.body.oneofKind !== "rpcCall" ||
      request.body.rpcCall.input.oneofKind !== "sendMessage"
    ) {
      throw new Error("Missing sendMessage request")
    }

    vi.spyOn(
      IDBObjectStore.prototype,
      "put",
    ).mockImplementationOnce(() => {
      throw new DOMException("disk full", "QuotaExceededError")
    })
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 2n,
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
                      updateMessageId: {
                        messageId: 900n,
                        randomId:
                          request.body.rpcCall.input.sendMessage
                            .randomId ?? 0n,
                      },
                    },
                  }),
                ],
              },
            },
          },
        },
      }),
    )

    expect(
      db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.PendingTransaction,
      ),
    ).toHaveLength(1)
    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          optimistic!.id,
        ),
      ),
    ).toMatchObject({
      message: "Keep until committed",
      status: "sending",
    })
    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          messageKey(chatId(10), messageId(900)),
        ),
      ),
    ).toBeUndefined()

    await expect(result).resolves.toMatchObject({
      oneofKind: "sendMessage",
    })
    expect(transport.sent.filter(rpcCall)).toHaveLength(1)
    expect(
      db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.PendingTransaction,
      ),
    ).toHaveLength(0)
    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          optimistic!.id,
        ),
      ),
    ).toBeUndefined()
    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          messageKey(chatId(10), messageId(900)),
        ),
      ),
    ).toMatchObject({
      message: "Keep until committed",
      status: "sent",
    })

    const reloaded = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    await reloaded.hydrateKinds([
      DbObjectKind.PendingTransaction,
    ])
    await reloaded.hydrateMessageWindow(chatId(10), {
      limit: 50,
    })
    expect(
      reloaded.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.PendingTransaction,
      ),
    ).toHaveLength(0)
    expect(
      reloaded.get(
        reloaded.ref(
          DbObjectKind.Message,
          messageKey(chatId(10), messageId(900)),
        ),
      ),
    ).toMatchObject({
      message: "Keep until committed",
      status: "sent",
    })
    await client.stop()
  })

  it("resends a failed message through the same durable idempotency identity", async () => {
    const auth = new AuthStore()
    const db = new Db({ autoHydrate: false, persistence: false })
    const transport = new MockTransport()
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      sync: false,
    })
    await client.startSession({ token: "token", userId: userId(7) })
    await connectAndOpen(transport)

    const firstResult = client.execute(
      sendMessage({
        chatId: chatId(10),
        peerId,
        text: "Retry exactly once",
      }),
    )
    await waitFor(() => transport.sent.filter(rpcCall).length === 1)
    const firstRequest = transport.sent.find(rpcCall)
    if (
      !firstRequest ||
      firstRequest.body.oneofKind !== "rpcCall" ||
      firstRequest.body.rpcCall.input.oneofKind !== "sendMessage"
    ) {
      throw new Error("Missing first sendMessage request")
    }
    const firstInput = firstRequest.body.rpcCall.input.sendMessage

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
    await expect(firstResult).rejects.toBeDefined()

    const [failedMessage] = db.queryCollection<
      DbObjectKind.Message,
      Message,
      DbQueryPlanType.Objects
    >(
      DbQueryPlanType.Objects,
      DbObjectKind.Message,
    )
    const [failedOutbox] = db.queryCollection<
      DbObjectKind.PendingTransaction,
      PendingTransaction,
      DbQueryPlanType.Objects
    >(
      DbQueryPlanType.Objects,
      DbObjectKind.PendingTransaction,
    )
    expect(failedMessage?.status).toBe(MessageSendingStatus.Failed)
    expect(failedOutbox?.status).toBe("failed")

    const resend = client.resendMessage(
      chatId(10),
      failedMessage!.messageId,
    )
    await waitFor(() => transport.sent.filter(rpcCall).length === 2)

    expect(
      db.get(
        db.ref(DbObjectKind.Message, failedMessage!.id),
      )?.status,
    ).toBe(MessageSendingStatus.Sending)
    expect(
      db.queryCollection<
        DbObjectKind.PendingTransaction,
        PendingTransaction,
        DbQueryPlanType.Objects
      >(
        DbQueryPlanType.Objects,
        DbObjectKind.PendingTransaction,
      ),
    ).toMatchObject([
      {
        id: failedOutbox!.id,
        status: "pending",
      },
    ])

    const secondRequest = transport.sent.filter(rpcCall)[1]
    if (
      !secondRequest ||
      secondRequest.body.oneofKind !== "rpcCall" ||
      secondRequest.body.rpcCall.input.oneofKind !== "sendMessage"
    ) {
      throw new Error("Missing resent sendMessage request")
    }
    expect(secondRequest.body.rpcCall.input.sendMessage.randomId).toBe(
      firstInput.randomId,
    )
    expect(secondRequest.body.rpcCall.input.sendMessage.temporarySendDate).toBe(
      firstInput.temporarySendDate,
    )

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
                        messageId: 901n,
                        randomId: firstInput.randomId ?? 0n,
                      },
                    },
                  }),
                ],
              },
            },
          },
        },
      }),
    )
    await expect(resend).resolves.toBeDefined()
    expect(
      db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.PendingTransaction,
      ),
    ).toHaveLength(0)
    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          messageKey(chatId(10), messageId(901)),
        ),
      ),
    ).toMatchObject({
      message: "Retry exactly once",
      status: MessageSendingStatus.Sent,
    })
    await client.stop()
  })

  it("keeps both failed records unchanged when resend persistence aborts", async () => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
    const auth = new AuthStore()
    const db = new Db({
      autoHydrate: false,
      storageNamespace: `outbox-resend-${crypto.randomUUID()}`,
    })
    const transport = new MockTransport()
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      sync: false,
    })
    await client.startSession({ token: "token", userId: userId(7) })
    await connectAndOpen(transport)

    const firstResult = client.execute(
      sendMessage({
        chatId: chatId(10),
        peerId,
        text: "Remain failed",
      }),
    )
    await waitFor(() => transport.sent.filter(rpcCall).length === 1)
    const request = transport.sent.find(rpcCall)
    if (!request) throw new Error("Missing failed send request")
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 2n,
        body: {
          oneofKind: "rpcError",
          rpcError: {
            reqMsgId: request.id,
            code: 400,
            errorCode: RpcError_Code.BAD_REQUEST,
            message: "SEND_FAILED",
          },
        },
      }),
    )
    await expect(firstResult).rejects.toBeDefined()
    const [failedMessage] = db.queryCollection<
      DbObjectKind.Message,
      Message,
      DbQueryPlanType.Objects
    >(
      DbQueryPlanType.Objects,
      DbObjectKind.Message,
    )
    const [failedOutbox] = db.queryCollection<
      DbObjectKind.PendingTransaction,
      PendingTransaction,
      DbQueryPlanType.Objects
    >(
      DbQueryPlanType.Objects,
      DbObjectKind.PendingTransaction,
    )

    vi.spyOn(
      IDBObjectStore.prototype,
      "put",
    ).mockImplementationOnce(() => {
      throw new DOMException("disk full", "QuotaExceededError")
    })
    await expect(
      client.resendMessage(
        chatId(10),
        failedMessage!.messageId,
      ),
    ).rejects.toBeDefined()

    expect(
      db.get(
        db.ref(DbObjectKind.Message, failedMessage!.id),
      )?.status,
    ).toBe(MessageSendingStatus.Failed)
    expect(
      db.get(
        db.ref(
          DbObjectKind.PendingTransaction,
          failedOutbox!.id,
        ),
      )?.status,
    ).toBe("failed")
    expect(transport.sent.filter(rpcCall)).toHaveLength(1)
    await client.stop()
  })
})
