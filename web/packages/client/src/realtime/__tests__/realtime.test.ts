import { describe, expect, it } from "vitest"
import {
  ConnectionError_Reason,
  ServerProtocolMessage,
  type ClientMessage,
} from "@inline-chat/protocol/core"
import { chatId, dialogId, messageId, userId } from "@inline/ids"
import {
  AuthStore,
  Db,
  DbObjectKind,
  DbQueryPlanType,
  messageKey,
  MessageSendingStatus,
  RealtimeClient,
} from "../../index"
import {
  editMessage,
  getChats,
  getMe,
  logOut,
  sendMessage,
  updateDialogOpen,
} from "../transactions"
import { MockTransport } from "../transport/mock-transport"
import { TransportError } from "../transport/transport"

const waitFor = async (predicate: () => boolean, timeoutMs = 300) => {
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

class FailNextRpcTransport extends MockTransport {
  rpcSendAttempts = 0
  failNextRpc = true

  override async send(message: ClientMessage) {
    if (message.body.oneofKind !== "rpcCall") {
      await super.send(message)
      return
    }

    this.rpcSendAttempts += 1
    if (this.failNextRpc) {
      this.failNextRpc = false
      throw TransportError.notConnected()
    }

    await super.send(message)
  }
}

class SlowRpcTransport extends MockTransport {
  activeRpcSends = 0
  maxActiveRpcSends = 0

  override async send(message: ClientMessage) {
    if (message.body.oneofKind !== "rpcCall") {
      await super.send(message)
      return
    }

    this.activeRpcSends += 1
    this.maxActiveRpcSends = Math.max(this.maxActiveRpcSends, this.activeRpcSends)
    await new Promise((resolve) => setTimeout(resolve, 10))
    await super.send(message)
    this.activeRpcSends -= 1
  }
}

describe("realtime connection flow", () => {
  it("sends connection init with token on connect", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db({ autoHydrate: false, persistence: false })
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      url: "ws://example.test",
      sync: false,
    })

    await client.startSession({ token: "test-token", userId: userId(42) })
    await transport.connect()

    await waitFor(() => transport.sent.length > 0)

    const initMessage = transport.sent[0]
    expect(initMessage.body.oneofKind).toBe("connectionInit")
    if (initMessage.body.oneofKind === "connectionInit") {
      expect(initMessage.body.connectionInit.token).toBe("test-token")
    }

    await client.stop()
  })

  it("moves to connected after connectionOpen", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db({ autoHydrate: false, persistence: false })
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      url: "ws://example.test",
      sync: false,
    })

    await client.startSession({ token: "test-token", userId: userId(1) })
    await connectAndOpen(transport)

    await waitFor(() => client.connectionState === "connected")

    expect(client.connectionState).toBe("connected")

    await client.stop()
  })

  it("logs out when the server invalidates connection credentials", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db({ autoHydrate: false, persistence: false })
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      url: "ws://example.test",
      sync: false,
    })

    await client.startSession({
      token: "revoked-token",
      userId: userId(1),
    })
    await transport.connect()
    await transport.emitMessage(
      ServerProtocolMessage.create({
        body: {
          oneofKind: "connectionError",
          connectionError: {
            reason:
              ConnectionError_Reason.SESSION_REVOKED,
          },
        },
      }),
    )
    await waitFor(() => !auth.isLoggedIn())

    expect(client.connectionState).toBe("idle")
    expect(client.connection.state).toBe("stopped")
  })

  it("executes getMe transaction and updates db", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db()
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      url: "ws://example.test",
      sync: false,
    })

    await client.startSession({ token: "test-token", userId: userId(1) })
    await connectAndOpen(transport)

    const resultPromise = client.execute(getMe())

    await waitFor(() => transport.sent.some((message) => message.body.oneofKind === "rpcCall"))
    const rpcCallMessage = transport.sent.find((message) => message.body.oneofKind === "rpcCall")
    if (!rpcCallMessage || rpcCallMessage.body.oneofKind !== "rpcCall") {
      throw new Error("Missing rpcCall message")
    }

    const rpcResult = ServerProtocolMessage.create({
      id: 2n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: rpcCallMessage.id,
          result: {
            oneofKind: "getMe",
            getMe: {
              user: {
                id: 99n,
                firstName: "Ada",
              },
            },
          },
        },
      },
    })

    await transport.emitMessage(rpcResult)
    await resultPromise

    const user = db.get(db.ref(DbObjectKind.User, userId(99)))
    expect(user?.firstName).toBe("Ada")

    await client.stop()
  })

  it("executes getChats transaction and updates db", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db()
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      url: "ws://example.test",
      sync: false,
    })

    await client.startSession({ token: "test-token", userId: userId(1) })
    await connectAndOpen(transport)

    const resultPromise = client.execute(getChats())

    await waitFor(() => transport.sent.some((message) => message.body.oneofKind === "rpcCall"))
    const rpcCallMessage = transport.sent.find((message) => message.body.oneofKind === "rpcCall")
    if (!rpcCallMessage || rpcCallMessage.body.oneofKind !== "rpcCall") {
      throw new Error("Missing rpcCall message")
    }

    const rpcResult = ServerProtocolMessage.create({
      id: 3n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: rpcCallMessage.id,
          result: {
            oneofKind: "getChats",
            getChats: {
              dialogs: [
                {
                  chatId: 10n,
                  peer: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
                },
              ],
              chats: [
                {
                  id: 10n,
                  title: "Test chat",
                },
              ],
              spaces: [],
              users: [
                {
                  id: 200n,
                  firstName: "Taylor",
                },
              ],
              messages: [
                {
                  id: 300n,
                  fromId: 200n,
                  chatId: 10n,
                  out: false,
                  date: 1000n,
                },
              ],
            },
          },
        },
      },
    })

    await transport.emitMessage(rpcResult)
    await resultPromise

    const chat = db.get(db.ref(DbObjectKind.Chat, chatId(10)))
    const dialog = db.get(db.ref(DbObjectKind.Dialog, dialogId(10)))
    const user = db.get(db.ref(DbObjectKind.User, userId(200)))
    const message = db.get(
      db.ref(
        DbObjectKind.Message,
        messageKey(chatId(10), messageId(300)),
      ),
    )

    expect(chat?.title).toBe("Test chat")
    expect(dialog?.chatId).toBe(chatId(10))
    expect(user?.firstName).toBe("Taylor")
    expect(message?.chatId).toBe(chatId(10))

    await client.stop()
  })

  it("accepts a durable mutation after its local outbox commit without waiting for RPC", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db({ autoHydrate: false, persistence: false })
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      url: "ws://example.test",
      sync: false,
    })
    db.insert({
      kind: DbObjectKind.Dialog,
      id: dialogId(-801),
      chatId: chatId(801),
      peerThreadId: chatId(801),
      open: true,
      order: "server-order",
    })

    await client.startSession({ token: "test-token", userId: userId(1) })
    await connectAndOpen(transport)

    await client.mutateAccepted(
      updateDialogOpen({
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 801n },
          },
        },
        open: true,
      }),
    )

    expect(
      db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))?.open,
    ).toBe(true)
    expect(
      db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.PendingTransaction,
        () => true,
      ),
    ).toHaveLength(1)
    await client.stop()
  })

  it("refuses local acceptance for a non-durable mutation", async () => {
    const auth = new AuthStore()
    const db = new Db({ autoHydrate: false, persistence: false })
    const client = new RealtimeClient({
      auth,
      db,
      transport: new MockTransport(),
      sync: false,
    })
    await expect(client.mutateAccepted(getMe())).rejects.toThrow(
      "Only durable Inline mutations expose local acceptance",
    )
  })

  it("runs logOut transaction locally", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db({ autoHydrate: false, persistence: false })
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      url: "ws://example.test",
      sync: false,
    })

    await client.startSession({ token: "test-token", userId: userId(1) })
    await connectAndOpen(transport)

    await client.execute(logOut())

    expect(auth.isLoggedIn()).toBe(false)
    expect(client.connectionState).toBe("idle")

    await client.stop()
  })

  it("pauses after one transport send failure and retries only after reconnect", async () => {
    const transport = new FailNextRpcTransport()
    const auth = new AuthStore()
    const db = new Db({ autoHydrate: false, persistence: false })
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      url: "ws://example.test",
      sync: false,
      connection: {
        backoffDelayMs: () => 40,
      },
    })

    await client.startSession({ token: "test-token", userId: userId(1) })
    await connectAndOpen(transport)

    const resultPromise = client.execute(getMe())

    await waitFor(() => transport.rpcSendAttempts === 1)
    await new Promise((resolve) => setTimeout(resolve, 25))

    expect(transport.rpcSendAttempts).toBe(1)
    expect(client.connectionState).toBe("connecting")
    expect(transport.state).toBe("idle")

    await waitFor(() => transport.state === "connecting")
    await connectAndOpen(transport)
    await waitFor(() => transport.rpcSendAttempts === 2)

    const rpcCallMessage = [...transport.sent]
      .reverse()
      .find((message) => message.body.oneofKind === "rpcCall")
    if (!rpcCallMessage || rpcCallMessage.body.oneofKind !== "rpcCall") {
      throw new Error("Missing retried rpcCall message")
    }

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 4n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpcCallMessage.id,
            result: {
              oneofKind: "getMe",
              getMe: {
                user: {
                  id: 1n,
                  firstName: "Retry",
                },
              },
            },
          },
        },
      }),
    )

    await resultPromise
    expect(client.connectionState).toBe("connected")

    await client.stop()
  })

  it("does not apply optimistic state again when a send is retried", async () => {
    const transport = new FailNextRpcTransport()
    const auth = new AuthStore()
    const db = new Db()
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      url: "ws://example.test",
      sync: false,
      connection: {
        backoffDelayMs: () => 0,
      },
    })

    await client.startSession({ token: "test-token", userId: userId(1) })
    await connectAndOpen(transport)

    const resultPromise = client.execute(
      sendMessage({
        chatId: chatId(10),
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 10n },
          },
        },
        text: "Exactly once",
      }),
    )

    await waitFor(() => transport.rpcSendAttempts === 1)
    expect(
      db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.Message,
        () => true,
      ),
    ).toHaveLength(1)

    await connectAndOpen(transport)
    await waitFor(() => transport.rpcSendAttempts === 2)

    const messages = db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.Message,
      () => true,
    )
    expect(messages).toHaveLength(1)
    expect(messages[0]).toMatchObject({
      message: "Exactly once",
      status: MessageSendingStatus.Sending,
    })

    await client.stop()
    await Promise.allSettled([resultPromise])
  })

  it("refuses to replay a non-idempotent mutation after transport handoff", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db()
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      url: "ws://example.test",
      sync: false,
      connection: {
        backoffDelayMs: () => 0,
      },
    })
    db.insert({
      kind: DbObjectKind.Message,
      id: messageKey(chatId(10), messageId(55)),
      messageId: messageId(55),
      chatId: chatId(10),
      fromId: userId(1),
      message: "Before",
      out: true,
      date: 1,
    })

    await client.startSession({ token: "test-token", userId: userId(1) })
    await connectAndOpen(transport)

    const result = client.execute(
      editMessage({
        chatId: chatId(10),
        messageId: messageId(55),
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 10n },
          },
        },
        text: "After",
      }),
    )
    await waitFor(
      () =>
        transport.sent.filter(
          (message) =>
            message.body.oneofKind === "rpcCall" &&
            message.body.rpcCall.input.oneofKind === "editMessage",
        ).length === 1,
    )

    await transport.disconnect()
    await waitFor(() => transport.state === "connecting")
    await connectAndOpen(transport)

    await expect(result).rejects.toMatchObject({ kind: "ambiguous-result" })
    expect(
      transport.sent.filter(
        (message) =>
          message.body.oneofKind === "rpcCall" &&
          message.body.rpcCall.input.oneofKind === "editMessage",
      ),
    ).toHaveLength(1)
    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          messageKey(chatId(10), messageId(55)),
        ),
      )?.message,
    ).toBe("Before")

    await client.stop()
  })

  it("drains transactions through one transport send at a time", async () => {
    const transport = new SlowRpcTransport()
    const auth = new AuthStore()
    const db = new Db({ autoHydrate: false, persistence: false })
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      url: "ws://example.test",
      sync: false,
    })

    await client.startSession({ token: "test-token", userId: userId(1) })
    await connectAndOpen(transport)

    const first = client.execute(getMe())
    const second = client.execute(getChats())

    await waitFor(
      () => transport.sent.filter((message) => message.body.oneofKind === "rpcCall").length === 2,
    )

    expect(transport.maxActiveRpcSends).toBe(1)

    await client.stop()
    await Promise.allSettled([first, second])
  })

  it("fails an invalid transaction once without reconnecting", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db({ autoHydrate: false, persistence: false })
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      url: "ws://example.test",
      sync: false,
    })

    await client.startSession({ token: "test-token", userId: userId(1) })
    await connectAndOpen(transport)

    const transaction = getMe()
    transaction.input = () => {
      throw new Error("invalid input")
    }

    await expect(client.execute(transaction)).rejects.toMatchObject({ kind: "invalid" })
    expect(client.connectionState).toBe("connected")
    expect(transport.state).toBe("connected")

    await client.stop()
  })
})
