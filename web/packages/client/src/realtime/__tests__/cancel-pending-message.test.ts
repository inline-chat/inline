import { describe, expect, it } from "vitest"
import {
  Method,
  ServerProtocolMessage,
} from "@inline-chat/protocol/core"
import { chatId, messageId, userId } from "@inline/ids"
import {
  AuthStore,
  Db,
  DbObjectKind,
  DbQueryPlanType,
  messageKey,
  RealtimeClient,
  type PendingTransaction,
  type CollectionStorage,
} from "../../index"
import { sendMessage } from "../transactions"
import { MockTransport } from "../transport/mock-transport"

const waitFor = async (predicate: () => boolean, timeoutMs = 300) => {
  const started = Date.now()
  while (Date.now() - started < timeoutMs) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  throw new Error("Timed out waiting for pending message")
}

describe("cancelPendingMessage", () => {
  it("atomically removes a queued durable send and repairs the chat tail", async () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const auth = new AuthStore()
    const targetChatId = chatId(10)
    const previousMessageId = messageId(4)
    db.insert({
      kind: DbObjectKind.Chat,
      id: targetChatId,
      lastMsgId: previousMessageId,
      date: 4,
    })
    db.insert({
      kind: DbObjectKind.Message,
      id: messageKey(targetChatId, previousMessageId),
      messageId: previousMessageId,
      chatId: targetChatId,
      fromId: userId(7),
      date: 4,
      message: "previous",
    })
    const client = new RealtimeClient({
      auth,
      db,
      transport: new MockTransport(),
      sync: false,
    })
    await client.startSession({ token: "test-token", userId: userId(7) })
    const transaction = sendMessage({
      chatId: targetChatId,
      text: "queued",
    })
    const temporaryMessageId = transaction.context.temporaryMessageId!
    const result = client.mutate(transaction)
    void result.catch(() => undefined)
    await waitFor(() =>
      db.get(
        db.ref(
          DbObjectKind.Message,
          messageKey(targetChatId, temporaryMessageId),
        ),
      ) != null,
    )

    await expect(
      client.cancelPendingMessage(targetChatId, temporaryMessageId),
    ).resolves.toBe(true)
    await expect(result).rejects.toThrow()
    expect(db.get(db.ref(
      DbObjectKind.Message,
      messageKey(targetChatId, temporaryMessageId),
    ))).toBeUndefined()
    expect(db.get(db.ref(DbObjectKind.Chat, targetChatId))?.lastMsgId).toBe(
      previousMessageId,
    )
    expect(db.queryCollection<
      DbObjectKind.PendingTransaction,
      PendingTransaction,
      DbQueryPlanType.Objects
    >(
      DbQueryPlanType.Objects,
      DbObjectKind.PendingTransaction,
      () => true,
    )).toEqual([])
    await client.stop()
  })

  it("keeps a send queued when durable cancellation fails", async () => {
    let failPendingDelete = false
    const rows = new Map<string, PendingTransaction>()
    const pendingStorage: CollectionStorage<PendingTransaction> = {
      init: async () => undefined,
      get: async (id) => rows.get(id),
      getAll: async () => Array.from(rows.values()),
      put: async (record) => {
        rows.set(record.id, record)
      },
      delete: async (id) => {
        if (failPendingDelete) {
          throw new Error("replica delete failed")
        }
        rows.delete(id)
      },
    }
    const noOpStorage: CollectionStorage<any> = {
      init: async () => undefined,
      get: async () => undefined,
      getAll: async () => [],
      put: async () => undefined,
      delete: async () => undefined,
    }
    const db = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.PendingTransaction]: pendingStorage,
        [DbObjectKind.Message]: noOpStorage,
        [DbObjectKind.Chat]: noOpStorage,
      },
    })
    const auth = new AuthStore()
    const transport = new MockTransport()
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      sync: false,
    })
    await client.startSession({ token: "test-token", userId: userId(7) })
    const targetChatId = chatId(10)
    const transaction = sendMessage({
      chatId: targetChatId,
      text: "survives failed cancellation",
    })
    const temporaryMessageId = transaction.context.temporaryMessageId!
    const result = client.mutate(transaction)
    void result.catch(() => undefined)
    await waitFor(() => rows.size === 1)

    failPendingDelete = true
    await expect(
      client.cancelPendingMessage(targetChatId, temporaryMessageId),
    ).rejects.toThrow("replica delete failed")
    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          messageKey(targetChatId, temporaryMessageId),
        ),
      ),
    ).toBeDefined()

    await transport.connect()
    await transport.emitMessage(
      ServerProtocolMessage.create({
        body: {
          oneofKind: "connectionOpen",
          connectionOpen: {},
        },
      }),
    )
    await waitFor(() =>
      transport.sent.some(
        (message) =>
          message.body.oneofKind === "rpcCall" &&
          message.body.rpcCall.method === Method.SEND_MESSAGE,
      ),
    )
    await client.stop()
  })
})
