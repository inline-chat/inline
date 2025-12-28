import { describe, expect, it } from "vitest"
import {
  ServerProtocolMessage,
  Update,
  type InputPeer,
  type Message,
  type UpdateDeleteMessages,
  type UpdateEditMessage,
  type UpdateMessageId,
} from "@in/protocol/core"
import { AuthStore, Db, DbObjectKind, RealtimeClient } from "../../index"
import {
  deleteMessages,
  editMessage,
  getChatHistory,
  sendMessage,
} from "../transactions"
import { MockTransport } from "../transport/mock-transport"
import { DbQueryPlanType } from "../../database/types"

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

const inputPeer: InputPeer = { type: { oneofKind: "chat", chat: { chatId: 10n } } }

const buildRpcResult = (reqMsgId: bigint, result: { oneofKind: string } & Record<string, unknown>) =>
  ServerProtocolMessage.create({
    id: 99n,
    body: {
      oneofKind: "rpcResult",
      rpcResult: {
        reqMsgId,
        result: result as any,
      },
    },
  })

describe("realtime transactions", () => {
  it("updates temporary message id from sendMessage updates", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db()
    const client = new RealtimeClient({ auth, db, transport, url: "ws://example.test" })

    await client.startSession({ token: "test-token", userId: 7 })
    await connectAndOpen(transport)

    const resultPromise = client.execute(
      sendMessage({
        chatId: 10,
        peerId: inputPeer,
        text: "Hello",
      }),
    )

    await waitFor(() => transport.sent.some((message) => message.body.oneofKind === "rpcCall"))

    const messages = db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message, () => true)
    expect(messages).toHaveLength(1)
    const tempMessage = messages[0]
    expect(tempMessage.message).toBe("Hello")
    expect(tempMessage.randomId).toBeDefined()

    const rpcCallMessage = transport.sent.find((message) => message.body.oneofKind === "rpcCall")
    if (!rpcCallMessage) throw new Error("Missing rpcCall message")

    const updateMessageId: UpdateMessageId = {
      messageId: 500n,
      randomId: tempMessage.randomId!,
    }

    const update = Update.create({ update: { oneofKind: "updateMessageId", updateMessageId } })

    await transport.emitMessage(
      buildRpcResult(rpcCallMessage.id, {
        oneofKind: "sendMessage",
        sendMessage: { updates: [update] },
      }),
    )

    await resultPromise

    const updatedMessage = db.get(db.ref(DbObjectKind.Message, 500))
    expect(updatedMessage?.message).toBe("Hello")
    expect(updatedMessage?.randomId).toBeUndefined()

    await client.stop()
  })

  it("applies editMessage updates", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db()
    const client = new RealtimeClient({ auth, db, transport, url: "ws://example.test" })

    db.insert({ kind: DbObjectKind.Message, id: 101, fromId: 1, chatId: 10, message: "Old", out: false })

    await client.startSession({ token: "test-token", userId: 1 })
    await connectAndOpen(transport)

    const resultPromise = client.execute(editMessage({ messageId: 101, peerId: inputPeer, text: "New" }))

    await waitFor(() => transport.sent.some((message) => message.body.oneofKind === "rpcCall"))
    const rpcCallMessage = transport.sent.find((message) => message.body.oneofKind === "rpcCall")
    if (!rpcCallMessage) throw new Error("Missing rpcCall message")

    const updated: Message = {
      id: 101n,
      fromId: 1n,
      chatId: 10n,
      out: false,
      message: "New",
      date: 1n,
    }

    const updateEditMessage: UpdateEditMessage = { message: updated }
    const update = Update.create({ update: { oneofKind: "editMessage", editMessage: updateEditMessage } })

    await transport.emitMessage(
      buildRpcResult(rpcCallMessage.id, {
        oneofKind: "editMessage",
        editMessage: { updates: [update] },
      }),
    )

    await resultPromise

    const message = db.get(db.ref(DbObjectKind.Message, 101))
    expect(message?.message).toBe("New")

    await client.stop()
  })

  it("applies deleteMessages updates", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db()
    const client = new RealtimeClient({ auth, db, transport, url: "ws://example.test" })

    db.insert({ kind: DbObjectKind.Message, id: 201, fromId: 1, chatId: 10, message: "Delete", out: false })

    await client.startSession({ token: "test-token", userId: 1 })
    await connectAndOpen(transport)

    const resultPromise = client.execute(deleteMessages({ messageIds: [201], peerId: inputPeer }))

    await waitFor(() => transport.sent.some((message) => message.body.oneofKind === "rpcCall"))
    const rpcCallMessage = transport.sent.find((message) => message.body.oneofKind === "rpcCall")
    if (!rpcCallMessage) throw new Error("Missing rpcCall message")

    const updateDeleteMessages: UpdateDeleteMessages = {
      messageIds: [201n],
      peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
    }

    const update = Update.create({ update: { oneofKind: "deleteMessages", deleteMessages: updateDeleteMessages } })

    await transport.emitMessage(
      buildRpcResult(rpcCallMessage.id, {
        oneofKind: "deleteMessages",
        deleteMessages: { updates: [update] },
      }),
    )

    await resultPromise

    const message = db.get(db.ref(DbObjectKind.Message, 201))
    expect(message).toBeUndefined()

    await client.stop()
  })

  it("upserts chat history messages", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db()
    const client = new RealtimeClient({ auth, db, transport, url: "ws://example.test" })

    await client.startSession({ token: "test-token", userId: 1 })
    await connectAndOpen(transport)

    const resultPromise = client.execute(getChatHistory({ peerId: inputPeer, limit: 1 }))

    await waitFor(() => transport.sent.some((message) => message.body.oneofKind === "rpcCall"))
    const rpcCallMessage = transport.sent.find((message) => message.body.oneofKind === "rpcCall")
    if (!rpcCallMessage) throw new Error("Missing rpcCall message")

    const message: Message = {
      id: 301n,
      fromId: 2n,
      chatId: 10n,
      out: false,
      message: "History",
      date: 1n,
    }

    await transport.emitMessage(
      buildRpcResult(rpcCallMessage.id, {
        oneofKind: "getChatHistory",
        getChatHistory: { messages: [message] },
      }),
    )

    await resultPromise

    const stored = db.get(db.ref(DbObjectKind.Message, 301))
    expect(stored?.message).toBe("History")

    await client.stop()
  })
})
