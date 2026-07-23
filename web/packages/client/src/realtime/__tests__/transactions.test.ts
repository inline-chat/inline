import { describe, expect, it } from "vitest"
import {
  ClientMessage,
  ServerProtocolMessage,
  RpcError_Code,
  MessageEntity_Type,
  Update,
  type InputPeer,
  type Message,
  type UpdateDeleteMessages,
  type UpdateEditMessage,
  type UpdateMessageId,
} from "@inline-chat/protocol/core"
import { chatId, messageId, userId } from "@inline/ids"
import {
  AuthStore,
  Db,
  DbObjectKind,
  messageKey,
  MessageSendingStatus,
  RealtimeClient,
} from "../../index"
import {
  deleteMessages,
  editMessage,
  getChatHistory,
  GetChatHistoryMode,
  getMessages,
  sendMessage,
  addReaction,
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
const threadChatId = chatId(10)

class EncodingMockTransport extends MockTransport {
  override async send(message: ClientMessage) {
    ClientMessage.toBinary(message)
    await super.send(message)
  }
}

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
  it("projects an optimistic reaction and settles it from the RPC update", async () => {
    const transport = new EncodingMockTransport()
    const auth = new AuthStore()
    const db = new Db()
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      url: "ws://example.test",
      sync: false,
    })
    const key = messageKey(threadChatId, messageId(20))
    db.insert({
      kind: DbObjectKind.Message,
      id: key,
      messageId: messageId(20),
      chatId: threadChatId,
      fromId: userId(8),
      message: "React here",
    })
    await client.startSession({ token: "test-token", userId: userId(7) })
    await connectAndOpen(transport)

    const resultPromise = client.execute(addReaction({
      emoji: "👍",
      chatId: threadChatId,
      messageId: messageId(20),
      peerId: inputPeer,
      intentId: "runtime-add",
    }))
    await waitFor(() =>
      db.get(db.ref(DbObjectKind.Message, key))?.reactionIntents?.length === 1,
    )
    const rpcCallMessage = transport.sent.find(
      (message) => message.body.oneofKind === "rpcCall",
    )
    if (!rpcCallMessage) throw new Error("Missing reaction rpcCall")

    await transport.emitMessage(buildRpcResult(rpcCallMessage.id, {
      oneofKind: "addReaction",
      addReaction: {
        updates: [Update.create({
          update: {
            oneofKind: "updateReaction",
            updateReaction: {
              reaction: {
                emoji: "👍",
                userId: 7n,
                messageId: 20n,
                chatId: 10n,
                date: 1_000n,
              },
            },
          },
        })],
      },
    }))
    await resultPromise

    const settled = db.get(db.ref(DbObjectKind.Message, key))
    expect(settled?.reactionIntents).toBeUndefined()
    expect(settled?.reactions?.reactions).toMatchObject([
      { emoji: "👍", userId: 7n },
    ])
    await client.stop()
  })

  it("updates temporary message id from sendMessage updates", async () => {
    const transport = new EncodingMockTransport()
    const auth = new AuthStore()
    const db = new Db()
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      url: "ws://example.test",
      sync: false,
    })
    db.insert({
      kind: DbObjectKind.Chat,
      id: threadChatId,
      title: "Thread",
      lastMsgId: messageId(1),
      date: 1,
    })

    await client.startSession({ token: "test-token", userId: userId(7) })
    await connectAndOpen(transport)

    const resultPromise = client.execute(
      sendMessage({
        chatId: threadChatId,
        peerId: inputPeer,
        text: "Hello",
        entities: {
          entities: [
            {
              type: MessageEntity_Type.BOLD,
              offset: 0n,
              length: 5n,
              entity: { oneofKind: undefined },
            },
          ],
        },
      }),
    )

    await waitFor(() => transport.sent.some((message) => message.body.oneofKind === "rpcCall"))

    const messages = db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message, () => true)
    expect(messages).toHaveLength(1)
    const tempMessage = messages[0]
    expect(tempMessage.message).toBe("Hello")
    expect(tempMessage.entities?.entities).toEqual([
      {
        type: MessageEntity_Type.BOLD,
        offset: 0n,
        length: 5n,
        entity: { oneofKind: undefined },
      },
    ])
    expect(tempMessage.randomId).toBeDefined()
    expect(tempMessage.status).toBe(MessageSendingStatus.Sending)
    expect(db.get(db.ref(DbObjectKind.Chat, threadChatId))).toMatchObject({
      lastMsgId: tempMessage.messageId,
      date: tempMessage.date,
    })

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

    const updatedMessage = db.get(
      db.ref(
        DbObjectKind.Message,
        messageKey(threadChatId, messageId(500)),
      ),
    )
    expect(updatedMessage?.message).toBe("Hello")
    expect(updatedMessage?.randomId).toBeUndefined()
    expect(updatedMessage?.status).toBe(MessageSendingStatus.Sent)
    expect(db.get(db.ref(DbObjectKind.Chat, threadChatId))?.lastMsgId).toBe(
      messageId(500),
    )
    expect(
      db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.PendingTransaction,
        () => true,
      ),
    ).toHaveLength(0)

    await client.stop()
  })

  it("marks an optimistic message as failed when sendMessage returns an rpc error", async () => {
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

    await client.startSession({ token: "test-token", userId: userId(7) })
    await connectAndOpen(transport)

    const resultPromise = client.execute(
      sendMessage({
        chatId: threadChatId,
        peerId: inputPeer,
        text: "Will fail",
      }),
    )
    await waitFor(() => transport.sent.some((message) => message.body.oneofKind === "rpcCall"))
    const rpcCallMessage = transport.sent.find((message) => message.body.oneofKind === "rpcCall")
    if (!rpcCallMessage) throw new Error("Missing rpcCall message")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 100n,
        body: {
          oneofKind: "rpcError",
          rpcError: {
            reqMsgId: rpcCallMessage.id,
            code: 400,
            errorCode: RpcError_Code.BAD_REQUEST,
            message: "SEND_FAILED",
          },
        },
      }),
    )
    await expect(resultPromise).rejects.toThrow()

    const messages = db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message, () => true)
    expect(messages).toHaveLength(1)
    expect(messages[0]?.status).toBe(MessageSendingStatus.Failed)
    expect(
      db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.PendingTransaction,
        () => true,
      ),
    ).toMatchObject([{ status: "failed", type: "send_message" }])

    await client.stop()
  })

  it("applies editMessage updates", async () => {
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

    db.insert({
      kind: DbObjectKind.Message,
      id: messageKey(threadChatId, messageId(101)),
      messageId: messageId(101),
      fromId: userId(1),
      chatId: threadChatId,
      message: "Old",
      out: false,
    })

    await client.startSession({ token: "test-token", userId: userId(1) })
    await connectAndOpen(transport)

    const resultPromise = client.execute(
      editMessage({
        chatId: threadChatId,
        messageId: messageId(101),
        peerId: inputPeer,
        text: "New",
      }),
    )

    await waitFor(() => transport.sent.some((message) => message.body.oneofKind === "rpcCall"))
    const rpcCallMessage = transport.sent.find((message) => message.body.oneofKind === "rpcCall")
    if (!rpcCallMessage) throw new Error("Missing rpcCall message")
    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          messageKey(threadChatId, messageId(101)),
        ),
      )?.message,
    ).toBe("Old")
    expect(
      db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.PendingTransaction,
        () => true,
      ),
    ).toHaveLength(0)

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

    const message = db.get(
      db.ref(
        DbObjectKind.Message,
        messageKey(threadChatId, messageId(101)),
      ),
    )
    expect(message?.message).toBe("New")

    await client.stop()
  })

  it("applies deleteMessages updates", async () => {
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

    db.insert({
      kind: DbObjectKind.Message,
      id: messageKey(threadChatId, messageId(201)),
      messageId: messageId(201),
      fromId: userId(1),
      chatId: threadChatId,
      message: "Delete",
      out: false,
    })

    await client.startSession({ token: "test-token", userId: userId(1) })
    await connectAndOpen(transport)

    const resultPromise = client.execute(
      deleteMessages({
        chatId: threadChatId,
        messageIds: [messageId(201)],
        peerId: inputPeer,
      }),
    )

    await waitFor(() => transport.sent.some((message) => message.body.oneofKind === "rpcCall"))
    const rpcCallMessage = transport.sent.find((message) => message.body.oneofKind === "rpcCall")
    if (!rpcCallMessage) throw new Error("Missing rpcCall message")
    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          messageKey(threadChatId, messageId(201)),
        ),
      ),
    ).toBeDefined()
    expect(
      db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.PendingTransaction,
        () => true,
      ),
    ).toHaveLength(0)

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

    const message = db.get(
      db.ref(
        DbObjectKind.Message,
        messageKey(threadChatId, messageId(201)),
      ),
    )
    expect(message).toBeUndefined()

    await client.stop()
  })

  it("upserts chat history messages", async () => {
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

    const resultPromise = client.execute(
      getChatHistory({
        peerId: inputPeer,
        mode: GetChatHistoryMode.HISTORY_MODE_OLDER,
        beforeId: messageId(400),
        limit: 1,
      }),
    )

    await waitFor(() => transport.sent.some((message) => message.body.oneofKind === "rpcCall"))
    const rpcCallMessage = transport.sent.find((message) => message.body.oneofKind === "rpcCall")
    if (
      !rpcCallMessage ||
      rpcCallMessage.body.oneofKind !== "rpcCall"
    ) {
      throw new Error("Missing rpcCall message")
    }
    expect(rpcCallMessage.body.rpcCall.input).toMatchObject({
      oneofKind: "getChatHistory",
      getChatHistory: {
        mode: GetChatHistoryMode.HISTORY_MODE_OLDER,
        beforeId: 400n,
      },
    })
    if (
      rpcCallMessage.body.rpcCall.input.oneofKind !==
      "getChatHistory"
    ) {
      throw new Error("Missing getChatHistory input")
    }
    expect(
      rpcCallMessage.body.rpcCall.input.getChatHistory,
    ).not.toHaveProperty("offsetId")

    const message: Message = {
      id: 301n,
      fromId: 2n,
      chatId: 10n,
      out: false,
      message: "History",
      date: 1n,
      groupedId: 88n,
      rev: 3n,
      media: {
        media: {
          oneofKind: "nudge",
          nudge: {},
        },
      },
      serviceMessage: {
        event: {
          oneofKind: "pinnedMessage",
          pinnedMessage: { messageId: 300n },
        },
      },
    }

    await transport.emitMessage(
      buildRpcResult(rpcCallMessage.id, {
        oneofKind: "getChatHistory",
        getChatHistory: { messages: [message] },
      }),
    )

    await resultPromise

    const stored = db.get(
      db.ref(
        DbObjectKind.Message,
        messageKey(threadChatId, messageId(301)),
      ),
    )
    expect(stored?.message).toBe("History")
    expect(stored).toMatchObject({
      groupedId: 88n,
      rev: 3n,
      media: {
        media: { oneofKind: "nudge" },
      },
      serviceMessage: {
        event: {
          oneofKind: "pinnedMessage",
          pinnedMessage: { messageId: 300n },
        },
      },
    })

    await client.stop()
  })

  it("fetches specific chat-scoped messages without loading history", async () => {
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

    const resultPromise = client.execute(
      getMessages({ peerId: inputPeer, messageIds: [messageId(42)] }),
    )

    await waitFor(() => transport.sent.some((message) => message.body.oneofKind === "rpcCall"))
    const rpcCallMessage = transport.sent.find((message) => message.body.oneofKind === "rpcCall")
    if (!rpcCallMessage || rpcCallMessage.body.oneofKind !== "rpcCall") {
      throw new Error("Missing rpcCall message")
    }
    expect(rpcCallMessage.body.rpcCall.input).toMatchObject({
      oneofKind: "getMessages",
      getMessages: {
        messageIds: [42n],
      },
    })

    await transport.emitMessage(
      buildRpcResult(rpcCallMessage.id, {
        oneofKind: "getMessages",
        getMessages: {
          messages: [
            {
              id: 42n,
              fromId: 2n,
              chatId: 10n,
              out: false,
              message: "Anchor",
              date: 1n,
            },
          ],
        },
      }),
    )

    await resultPromise

    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          messageKey(threadChatId, messageId(42)),
        ),
      )?.message,
    ).toBe("Anchor")

    await client.stop()
  })
})
