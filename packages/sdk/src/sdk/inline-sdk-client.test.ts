import { describe, expect, it, vi } from "vitest"
import { GetUpdatesResult_ResultType, Method, ServerProtocolMessage, Update } from "@inline-chat/protocol/core"
import { InlineSdkClient } from "./inline-sdk-client.js"
import { MockTransport } from "../realtime/mock-transport.js"
import type { InlineSdkState, InlineSdkStateStore } from "./types.js"

const waitFor = async (predicate: () => boolean, timeoutMs = 300) => {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    if (predicate()) return
    await new Promise((r) => setTimeout(r, 5))
  }
  throw new Error("Timed out waiting for condition")
}

const connectAndOpen = async (client: InlineSdkClient, transport: MockTransport) => {
  const connectPromise = client.connect()
  await transport.connect()

  // Connection init should be sent immediately after transport connect.
  await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "connectionInit"))

  await transport.emitMessage(
    ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }),
  )

  await connectPromise
}

class MemoryStateStore implements InlineSdkStateStore {
  loaded: InlineSdkState | null
  saved: InlineSdkState[] = []
  constructor(initial?: InlineSdkState) {
    this.loaded = initial ?? null
  }
  async load() {
    return this.loaded
  }
  async save(next: InlineSdkState) {
    this.saved.push(next)
    this.loaded = next
  }
}

describe("InlineSdkClient", () => {
  it("can be constructed without a custom transport and close() is a no-op before connect()", async () => {
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
    })

    await expect(client.close()).resolves.toBeUndefined()
  })

  it("includes internal layer + sdk version in connectionInit", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    const connectPromise = client.connect()
    await transport.connect()

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "connectionInit"))
    const init = transport.sent.find((m) => m.body.oneofKind === "connectionInit")
    if (!init || init.body.oneofKind !== "connectionInit") throw new Error("missing connectionInit")

    expect(init.body.connectionInit.layer).toBe(1)
    expect(typeof init.body.connectionInit.clientVersion).toBe("string")

    await transport.emitMessage(
      ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }),
    )

    await connectPromise
    await client.close()
  })

  it("connect() can be awaited multiple times (in-flight and after open)", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    const p1 = client.connect()
    const p2 = client.connect()

    await transport.connect()
    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "connectionInit"))
    await transport.emitMessage(ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }))

    await expect(Promise.all([p1, p2])).resolves.toBeDefined()

    // Calling connect() after open should be a no-op.
    await expect(client.connect()).resolves.toBeUndefined()

    await client.close()
  })

  it("connect() rejects if the AbortSignal is already aborted", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    const controller = new AbortController()
    controller.abort()

    await expect(client.connect(controller.signal)).rejects.toThrow(/aborted/)
  })

  it("connect() rejects if aborted before open, and close() unblocks pending connect", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    const controller = new AbortController()
    const p = client.connect(controller.signal)

    controller.abort()
    await expect(p).rejects.toThrow(/aborted|closed/)
  })

  it("connect() can be retried after a transport start failure", async () => {
    class FlakyStartTransport extends MockTransport {
      private startCalls = 0
      override async start() {
        this.startCalls++
        if (this.startCalls === 1) {
          throw new Error("start-failed")
        }
        return await super.start()
      }
    }

    const transport = new FlakyStartTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await expect(client.connect()).rejects.toThrow(/start-failed/)

    const connectPromise = client.connect()
    await transport.connect()
    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "connectionInit"))
    await transport.emitMessage(
      ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }),
    )
    await expect(connectPromise).resolves.toBeUndefined()

    await client.close()
  })

  it("connect() authenticates and getMe() works", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const p = client.getMe()

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall"))
    const rpc = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_ME,
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing rpc")
    expect(rpc.body.rpcCall.method).toBe(Method.GET_ME)
    expect(rpc.body.rpcCall.input.oneofKind).toBe("getMe")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 2n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: { oneofKind: "getMe", getMe: { user: { id: 42n, firstName: "Ada" } } },
          },
        },
      }),
    )

    await expect(p).resolves.toEqual({ userId: 42n })
    await client.close()
  })

  it("getChat() works", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const p = client.getChat({ chatId: 7 })

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall"))
    const rpc = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_CHAT,
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing rpc")
    expect(rpc.body.rpcCall.method).toBe(Method.GET_CHAT)
    expect(rpc.body.rpcCall.input.oneofKind).toBe("getChat")
    if (rpc.body.rpcCall.input.oneofKind !== "getChat") throw new Error("missing getChat")
    expect(rpc.body.rpcCall.input.getChat.peerId?.type.oneofKind).toBe("chat")
    if (rpc.body.rpcCall.input.getChat.peerId?.type.oneofKind === "chat") {
      expect(rpc.body.rpcCall.input.getChat.peerId.type.chat.chatId).toBe(7n)
    }

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 3n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: {
              oneofKind: "getChat",
              getChat: {
                chat: { id: 7n, title: "Test thread" },
                pinnedMessageIds: [],
              },
            },
          },
        },
      }),
    )

    await expect(p).resolves.toEqual({ chatId: 7n, peer: undefined, title: "Test thread" })
    await client.close()
  })

  it("getMessages() accepts chatId target and returns messages", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const p = client.getMessages({ chatId: 7, messageIds: [11, 12n] })

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall"))
    const rpc = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_MESSAGES,
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing rpc")
    expect(rpc.body.rpcCall.input.oneofKind).toBe("getMessages")
    if (rpc.body.rpcCall.input.oneofKind !== "getMessages") throw new Error("missing getMessages")
    expect(rpc.body.rpcCall.input.getMessages.peerId?.type.oneofKind).toBe("chat")
    if (rpc.body.rpcCall.input.getMessages.peerId?.type.oneofKind === "chat") {
      expect(rpc.body.rpcCall.input.getMessages.peerId.type.chat.chatId).toBe(7n)
    }
    expect(rpc.body.rpcCall.input.getMessages.messageIds).toEqual([11n, 12n])

    const messages = [
      {
        id: 11n,
        fromId: 42n,
        peerId: { type: { oneofKind: "chat", chat: { chatId: 7n } } },
        chatId: 7n,
        out: false,
        date: 100n,
        message: "a",
      },
      {
        id: 12n,
        fromId: 43n,
        peerId: { type: { oneofKind: "chat", chat: { chatId: 7n } } },
        chatId: 7n,
        out: true,
        date: 101n,
        message: "b",
      },
    ]

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 4n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: {
              oneofKind: "getMessages",
              getMessages: {
                messages,
              },
            },
          },
        },
      }),
    )

    await expect(p).resolves.toEqual({ messages })
    await client.close()
  })

  it("getMessages() accepts userId target", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const p = client.getMessages({ userId: 42, messageIds: [77] })

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall"))
    const rpc = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_MESSAGES,
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing rpc")
    if (rpc.body.rpcCall.input.oneofKind !== "getMessages") throw new Error("missing getMessages")
    expect(rpc.body.rpcCall.input.getMessages.peerId?.type.oneofKind).toBe("user")
    if (rpc.body.rpcCall.input.getMessages.peerId?.type.oneofKind === "user") {
      expect(rpc.body.rpcCall.input.getMessages.peerId.type.user.userId).toBe(42n)
    }
    expect(rpc.body.rpcCall.input.getMessages.messageIds).toEqual([77n])

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 5n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: {
              oneofKind: "getMessages",
              getMessages: {
                messages: [],
              },
            },
          },
        },
      }),
    )

    await expect(p).resolves.toEqual({ messages: [] })
    await client.close()
  })

  it("getMessages() rejects invalid target selection", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    await expect(
      client.getMessages({
        chatId: 7,
        userId: 42,
        messageIds: [1],
      } as any),
    ).rejects.toThrow(/exactly one of `chatId` or `userId`/)

    await expect(
      client.getMessages({
        messageIds: [1],
      } as any),
    ).rejects.toThrow(/exactly one of `chatId` or `userId`/)

    await client.close()
  })

  it("sendMessage() accepts number chatId and uses sendMode", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const p = client.sendMessage({ chatId: 7, text: "hi", sendMode: "silent", parseMarkdown: true })

    await waitFor(() => transport.sent.filter((m) => m.body.oneofKind === "rpcCall").length > 0)
    const rpc = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.SEND_MESSAGE,
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing rpc")
    expect(rpc.body.rpcCall.method).toBe(Method.SEND_MESSAGE)
    if (rpc.body.rpcCall.input.oneofKind !== "sendMessage") throw new Error("missing sendMessage")
    expect(rpc.body.rpcCall.input.sendMessage.peerId?.type.oneofKind).toBe("chat")
    if (rpc.body.rpcCall.input.sendMessage.peerId?.type.oneofKind === "chat") {
      expect(rpc.body.rpcCall.input.sendMessage.peerId.type.chat.chatId).toBe(7n)
    }
    expect(rpc.body.rpcCall.input.sendMessage.sendMode).toBe(1) // MODE_SILENT
    expect(rpc.body.rpcCall.input.sendMessage.parseMarkdown).toBe(true)

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 3n,
        body: { oneofKind: "rpcResult", rpcResult: { reqMsgId: rpc.id, result: { oneofKind: "sendMessage", sendMessage: { updates: [] } } } },
      }),
    )

    await expect(p).resolves.toEqual({ messageId: null })
    await client.close()
  })

  it("sendMessage() accepts userId destination", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const p = client.sendMessage({ userId: 42, text: "hi" })

    await waitFor(() => transport.sent.filter((m) => m.body.oneofKind === "rpcCall").length > 0)
    const rpc = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.SEND_MESSAGE,
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing rpc")
    if (rpc.body.rpcCall.input.oneofKind !== "sendMessage") throw new Error("missing sendMessage")

    expect(rpc.body.rpcCall.input.sendMessage.peerId?.type.oneofKind).toBe("user")
    if (rpc.body.rpcCall.input.sendMessage.peerId?.type.oneofKind === "user") {
      expect(rpc.body.rpcCall.input.sendMessage.peerId.type.user.userId).toBe(42n)
    }

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 3n,
        body: { oneofKind: "rpcResult", rpcResult: { reqMsgId: rpc.id, result: { oneofKind: "sendMessage", sendMessage: { updates: [] } } } },
      }),
    )

    await expect(p).resolves.toEqual({ messageId: null })
    await client.close()
  })

  it("sendMessage() returns messageId when present in updates", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const p = client.sendMessage({ chatId: 7, text: "hi" })

    await waitFor(() => transport.sent.filter((m) => m.body.oneofKind === "rpcCall").length > 0)
    const rpc = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.SEND_MESSAGE,
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing rpc")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 3n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: {
              oneofKind: "sendMessage",
              sendMessage: {
                updates: [
                  Update.create({
                    seq: 1,
                    date: 1n,
                    update: {
                      oneofKind: "newMessage",
                      newMessage: {
                        message: {
                          id: 123n,
                          fromId: 99n,
                          peerId: { type: { oneofKind: "chat", chat: { chatId: 7n } } },
                          chatId: 7n,
                          out: true,
                          date: 1n,
                        },
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

    await expect(p).resolves.toEqual({ messageId: 123n })
    await client.close()
  })

  it("sendMessage() rejects specifying both entities and parseMarkdown", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    await expect(
      client.sendMessage({
        chatId: 7,
        text: "hi",
        parseMarkdown: true,
        entities: {},
      } as any),
    ).rejects.toThrow(/either `entities` or `parseMarkdown`/)

    await client.close()
  })

  it("sendMessage() rejects invalid target selection", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    await expect(
      client.sendMessage({
        chatId: 7,
        userId: 42,
        text: "hi",
      } as any),
    ).rejects.toThrow(/exactly one of `chatId` or `userId`/)

    await expect(
      client.sendMessage({
        text: "hi",
      } as any),
    ).rejects.toThrow(/exactly one of `chatId` or `userId`/)

    await client.close()
  })

  it("invokeRaw() rejects method/input mismatches", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    await expect(
      client.invokeRaw(Method.GET_ME, {
        oneofKind: "sendMessage",
        // @ts-expect-error intentionally wrong for test
        sendMessage: {},
      }),
    ).rejects.toThrow(/expects getMe/)

    await client.close()
  })

  it("invokeRaw() works for known methods and validates results", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const p = client.invokeRaw(Method.GET_ME, { oneofKind: "getMe", getMe: {} })

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_ME))
    const rpc = transport.sent.find((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_ME)
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing rpc")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 2n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: { reqMsgId: rpc.id, result: { oneofKind: "getMe", getMe: { user: { id: 1n } } } },
        },
      }),
    )

    await expect(p).resolves.toBeDefined()
    await client.close()
  })

  it("invokeRaw() supports unknown methods (forward-compat) without validation", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const p = client.invokeRaw(999 as any, { oneofKind: undefined })

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && (m.body.rpcCall.method as any) === 999))
    const rpc = transport.sent.find((m) => m.body.oneofKind === "rpcCall" && (m.body.rpcCall.method as any) === 999)
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing rpc")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 2n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: { reqMsgId: rpc.id, result: { oneofKind: "getMe", getMe: { user: { id: 1n } } } },
        },
      }),
    )

    const result = await p
    expect(result.oneofKind).toBe("getMe")
    await client.close()
  })

  it("invokeUncheckedRaw() bypasses validation for known methods", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    // UNSPECIFIED normally has no input mapping; unchecked should still send.
    const p = client.invokeUncheckedRaw(Method.UNSPECIFIED, { oneofKind: "getMe", getMe: {} } as any)

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.UNSPECIFIED))
    const rpc = transport.sent.find((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.UNSPECIFIED)
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing rpc")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 2n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: { reqMsgId: rpc.id, result: { oneofKind: undefined } },
        },
      }),
    )

    await expect(p).resolves.toEqual({ oneofKind: undefined })
    await client.close()
  })

  it("invoke() rejects method/result mismatches", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const p = client.invoke(Method.GET_ME, { oneofKind: "getMe", getMe: {} })
    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_ME))
    const rpc = transport.sent.find((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_ME)
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing rpc")

    // Reply with the wrong oneof kind.
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 2n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: { reqMsgId: rpc.id, result: { oneofKind: "sendMessage", sendMessage: { updates: [] } } },
        },
      }),
    )

    await expect(p).rejects.toThrow(/rpc result mismatch/)
    await client.close()
  })

  it("emits normalized inbound events and performs chat catch-up when state store is provided", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1, lastSeqByChatId: { "10": 1 } })
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
    })

    await connectAndOpen(client, transport)

    const iter = client.events()[Symbol.asyncIterator]()

    // Live update: new message
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 10n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 2,
                    date: 100n,
                    update: { oneofKind: "newMessage", newMessage: { message: { id: 1n, chatId: 10n, fromId: 2n, peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } }, out: false, date: 100n } } },
                  }),
                ],
              },
            },
          },
        },
      }),
    )

    const ev1 = await iter.next()
    expect(ev1.done).toBe(false)
    expect(ev1.value.kind).toBe("message.new")

    // Trigger catch-up
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 11n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 3,
                    date: 101n,
                    update: {
                      oneofKind: "chatHasNewUpdates",
                      chatHasNewUpdates: { chatId: 10n, updateSeq: 5, peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } } },
                    },
                  }),
                ],
              },
            },
          },
        },
      }),
    )

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES))
    const rpc = transport.sent.find((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES)
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates rpc")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 12n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: {
              oneofKind: "getUpdates",
              getUpdates: {
                updates: [
                  Update.create({
                    seq: 4,
                    date: 102n,
                    update: {
                      oneofKind: "deleteMessages",
                      deleteMessages: {
                        messageIds: [1n],
                        peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
                      },
                    },
                  }),
                ],
                seq: 5n,
                date: 102n,
                resultType: 2,
              },
            },
          },
        },
      }),
    )

    // The delete event should come through after catch-up.
    const ev2 = await iter.next()
    expect(ev2.value.kind).toBe("chat.hasUpdates")
    const ev3 = await iter.next()
    expect(ev3.value.kind).toBe("message.delete")
    if (ev3.value.kind === "message.delete") {
      expect(ev3.value.seq).toBe(4)
    }

    expect(client.exportState().lastSeqByChatId?.["10"]).toBe(5)
    await client.close()

    // State persisted (close() flushes).
    expect(store.saved.length).toBeGreaterThan(0)
    expect(store.loaded?.lastSeqByChatId?.["10"]).toBe(5)
  })

  it("supports sendTyping, updates dateCursor when GET_UPDATES_STATE succeeds, and skips deleteMessages without chat peer", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 2 as any })
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
    })

    await connectAndOpen(client, transport)

    // Respond to GET_UPDATES_STATE so dateCursor is set.
    await waitFor(() =>
      transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES_STATE),
    )
    const getUpdatesStateCall = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES_STATE,
    )
    if (!getUpdatesStateCall || getUpdatesStateCall.body.oneofKind !== "rpcCall") throw new Error("missing getUpdatesState")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 100n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: getUpdatesStateCall.id,
            result: { oneofKind: "getUpdatesState", getUpdatesState: { date: 500n } },
          },
        },
      }),
    )

    await waitFor(() => client.exportState().dateCursor === 500n)

    // sendTyping()
    const typingPromise = client.sendTyping({ chatId: 10, typing: true })
    await waitFor(() =>
      transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.SEND_COMPOSE_ACTION),
    )
    const typingCall = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.SEND_COMPOSE_ACTION,
    )
    if (!typingCall || typingCall.body.oneofKind !== "rpcCall") throw new Error("missing typing")
    if (typingCall.body.rpcCall.input.oneofKind !== "sendComposeAction") throw new Error("missing sendComposeAction")
    expect(typingCall.body.rpcCall.input.sendComposeAction.action).toBe(1) // TYPING

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 101n,
        body: { oneofKind: "rpcResult", rpcResult: { reqMsgId: typingCall.id, result: { oneofKind: "sendComposeAction", sendComposeAction: {} } } },
      }),
    )
    await typingPromise

    // method/input mismatch for UNSPECIFIED expects no input.
    await expect(client.invokeRaw(Method.UNSPECIFIED, { oneofKind: "getMe", getMe: {} })).rejects.toThrow(/expects no input/)

    // deleteMessages without chat peer should be skipped (no message.delete event).
    const iter = client.events()[Symbol.asyncIterator]()
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 200n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 1,
                    date: 1n,
                    update: {
                      oneofKind: "deleteMessages",
                      deleteMessages: { messageIds: [1n], peerId: { type: { oneofKind: "user", user: { userId: 1n } } } },
                    },
                  }),
                ],
              },
            },
          },
        },
      }),
    )

    const pending = iter.next()
    const raced = await Promise.race([
      pending,
      new Promise<{ timeout: true }>((resolve) => setTimeout(() => resolve({ timeout: true }), 25)),
    ])

    expect("timeout" in raced).toBe(true)

    await client.close()
    await pending
  })

  it("covers state save scheduling/in-flight paths and GET_UPDATES too-long fast-forward", async () => {
    let saveResolve: (() => void) | null = null
    let saveCalls = 0
    const store: InlineSdkStateStore = {
      async load() {
        return { version: 1, lastSeqByChatId: { "10": 1 } }
      },
      async save(_next) {
        saveCalls++
        await new Promise<void>((r) => {
          saveResolve = r
        })
      },
    }

    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
    })

    await connectAndOpen(client, transport)

    vi.useFakeTimers()

    // Trigger bumpChatSeq twice quickly; second should see saveTimer already present.
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 10n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 2,
                    date: 100n,
                    update: { oneofKind: "newMessage", newMessage: { message: { id: 1n, chatId: 10n, fromId: 2n, peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } }, out: false, date: 100n } } },
                  }),
                  Update.create({
                    seq: 3,
                    date: 101n,
                    update: { oneofKind: "editMessage", editMessage: { message: { id: 1n, chatId: 10n, fromId: 2n, peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } }, out: false, date: 101n } } },
                  }),
                ],
              },
            },
          },
        },
      }),
    )

    // Let the save timer fire; save stays in-flight until we resolve it.
    await vi.advanceTimersByTimeAsync(250)
    expect(saveCalls).toBe(1)
    expect(saveResolve).not.toBeNull()

    // While save is in-flight, force another save flush path by closing.
    const closing = client.close()
    // Unblock save
    saveResolve?.()
    await closing

    vi.useRealTimers()

    // Now cover GET_UPDATES too-long fast-forward behavior.
    const transport2 = new MockTransport()
    let warned = 0
    const client2 = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport: transport2,
      state: new MemoryStateStore({ version: 1, lastSeqByChatId: { "10": 1 } }),
      logger: { warn: () => warned++ } as any,
    })

    await connectAndOpen(client2, transport2)

    // Trigger catch-up.
    await transport2.emitMessage(
      ServerProtocolMessage.create({
        id: 11n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 3,
                    date: 101n,
                    update: {
                      oneofKind: "chatHasNewUpdates",
                      chatHasNewUpdates: { chatId: 10n, updateSeq: 5, peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } } },
                    },
                  }),
                ],
              },
            },
          },
        },
      }),
    )

    await waitFor(() => transport2.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES))
    const rpc = transport2.sent.find((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES)
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates rpc")

    await transport2.emitMessage(
      ServerProtocolMessage.create({
        id: 12n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: {
              oneofKind: "getUpdates",
              getUpdates: {
                updates: [],
                seq: 5n,
                date: 222n,
                // RESULT_TYPE_TOO_LONG
                resultType: GetUpdatesResult_ResultType.TOO_LONG,
              },
            },
          },
        },
      }),
    )

    await waitFor(() => client2.exportState().dateCursor === 222n)
    expect(warned).toBeGreaterThan(0)
    await client2.close()
  })

  it("GET_UPDATES_STATE failure is treated as best-effort and does not block connect", async () => {
    const transport = new MockTransport()
    let warned = 0
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      logger: { warn: () => warned++ } as any,
    })

    await connectAndOpen(client, transport)

    // Find and fail GET_UPDATES_STATE call (best-effort).
    await waitFor(() =>
      transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES_STATE),
    )
    const call = transport.sent.find((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES_STATE)
    if (!call || call.body.oneofKind !== "rpcCall") throw new Error("missing getUpdatesState call")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 99n,
        body: { oneofKind: "rpcError", rpcError: { reqMsgId: call.id, errorCode: 2, message: "nope", code: 500 } },
      }),
    )

    await waitFor(() => warned > 0)
    await client.close()
  })

  it("listener crash rejects connect() and logs", async () => {
    const transport = new MockTransport()
    let errored = 0
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      logger: { error: () => errored++ } as any,
    })

    // Force the SDK listener to crash when it sees an open event.
    ;(client as any).onOpen = async () => {
      throw new Error("boom")
    }

    const p = client.connect()
    await transport.connect()
    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "connectionInit"))
    await transport.emitMessage(ServerProtocolMessage.create({ id: 1n, body: { oneofKind: "connectionOpen", connectionOpen: {} } }))

    await expect(p).rejects.toThrow(/boom|listener-crashed/)
    expect(errored).toBeGreaterThan(0)
  })

  it("covers peerToInputPeer user/default cases and state persistence failure logging", async () => {
    let warned = 0
    const store: InlineSdkStateStore = {
      async load() {
        return { version: 1 }
      },
      async save(_next) {
        throw new Error("nope")
      },
    }

    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
      logger: { warn: () => warned++ } as any,
    })

    await connectAndOpen(client, transport)

    vi.useFakeTimers()

    // Force a save attempt (and failure).
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 10n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 1,
                    date: 1n,
                    update: { oneofKind: "newMessage", newMessage: { message: { id: 1n, chatId: 10n, fromId: 2n, peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } }, out: false, date: 1n } } },
                  }),
                ],
              },
            },
          },
        },
      }),
    )
    await vi.advanceTimersByTimeAsync(250)
    await Promise.resolve()
    expect(warned).toBeGreaterThan(0)

    // Cover peerToInputPeer() branches via direct call.
    const asAny = client as any
    const peerUser = { type: { oneofKind: "user", user: { userId: 9n } } }
    const out1 = asAny.peerToInputPeer(peerUser, 10n)
    expect(out1.type.oneofKind).toBe("user")

    const peerWeird = { type: { oneofKind: undefined } }
    const out2 = asAny.peerToInputPeer(peerWeird, 10n)
    expect(out2.type.oneofKind).toBe("chat")

    await client.close()
    vi.useRealTimers()
  })

  it("covers GET_UPDATES catch-up when peer is omitted (peerToInputPeer default path)", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1, lastSeqByChatId: { "10": 1 } })
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
    })

    await connectAndOpen(client, transport)

    // Trigger catch-up with no peerId set.
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 11n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 3,
                    date: 101n,
                    update: {
                      oneofKind: "chatHasNewUpdates",
                      chatHasNewUpdates: { chatId: 10n, updateSeq: 5 },
                    },
                  }),
                ],
              },
            },
          },
        },
      }),
    )

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES))
    const rpc = transport.sent.find((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES)
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates rpc")

    // Ensure the bucket peerId defaults to chat.
    if (rpc.body.rpcCall.input.oneofKind !== "getUpdates") throw new Error("missing getUpdates input")
    expect(rpc.body.rpcCall.input.getUpdates.bucket?.type.oneofKind).toBe("chat")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 12n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: { oneofKind: "getUpdates", getUpdates: { updates: [], seq: 5n, date: 111n, resultType: GetUpdatesResult_ResultType.SLICE } },
          },
        },
      }),
    )

    await waitFor(() => client.exportState().dateCursor === 111n)
    await client.close()
  })

  it("GET_UPDATES catch-up loops across multiple slices until endSeq", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1, lastSeqByChatId: { "10": 1 } })
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
    })

    await connectAndOpen(client, transport)

    // Trigger catch-up from seq 1 -> 6, requiring two slices (1->3 and 3->6).
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 11n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 2,
                    date: 101n,
                    update: {
                      oneofKind: "chatHasNewUpdates",
                      chatHasNewUpdates: { chatId: 10n, updateSeq: 6, peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } } },
                    },
                  }),
                ],
              },
            },
          },
        },
      }),
    )

    // First GET_UPDATES call: startSeq=1
    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES))
    const rpc1 = transport.sent.find((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES)
    if (!rpc1 || rpc1.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates rpc1")
    if (rpc1.body.rpcCall.input.oneofKind !== "getUpdates") throw new Error("missing getUpdates input1")
    expect(rpc1.body.rpcCall.input.getUpdates.startSeq).toBe(1n)

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 12n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc1.id,
            result: {
              oneofKind: "getUpdates",
              getUpdates: {
                updates: [],
                seq: 3n,
                date: 111n,
                resultType: GetUpdatesResult_ResultType.SLICE,
                final: false,
              },
            },
          },
        },
      }),
    )

    // Second GET_UPDATES call: startSeq=3
    await waitFor(
      () => transport.sent.filter((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES).length >= 2,
    )
    const rpc2 = transport.sent
      .filter((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES)
      .at(1)
    if (!rpc2 || rpc2.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates rpc2")
    if (rpc2.body.rpcCall.input.oneofKind !== "getUpdates") throw new Error("missing getUpdates input2")
    expect(rpc2.body.rpcCall.input.getUpdates.startSeq).toBe(3n)

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 13n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc2.id,
            result: {
              oneofKind: "getUpdates",
              getUpdates: {
                updates: [],
                seq: 6n,
                date: 222n,
                resultType: GetUpdatesResult_ResultType.SLICE,
                final: false,
              },
            },
          },
        },
      }),
    )

    await waitFor(() => client.exportState().lastSeqByChatId?.["10"] === 6)
    await waitFor(() => client.exportState().dateCursor === 222n)
    await client.close()
  })

  it("GET_UPDATES catch-up respects final=true even if endSeq is higher", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1, lastSeqByChatId: { "10": 1 } })
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
    })

    await connectAndOpen(client, transport)

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 11n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 2,
                    date: 101n,
                    update: {
                      oneofKind: "chatHasNewUpdates",
                      chatHasNewUpdates: { chatId: 10n, updateSeq: 10, peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } } },
                    },
                  }),
                ],
              },
            },
          },
        },
      }),
    )

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES))
    const rpc = transport.sent.find((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES)
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates rpc")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 12n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: {
              oneofKind: "getUpdates",
              getUpdates: {
                updates: [],
                seq: 5n,
                date: 123n,
                resultType: GetUpdatesResult_ResultType.SLICE,
                final: true,
              },
            },
          },
        },
      }),
    )

    await waitFor(() => client.exportState().lastSeqByChatId?.["10"] === 5)

    // Should not request another slice even though endSeq=10.
    await new Promise((r) => setTimeout(r, 25))
    const getUpdatesCalls = transport.sent.filter((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES)
    expect(getUpdatesCalls.length).toBe(1)

    await client.close()
  })

  it("GET_UPDATES catch-up aborts on non-safe-integer seq and logs", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1, lastSeqByChatId: { "10": 1 } })
    let warned = 0
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
      logger: { warn: () => warned++ } as any,
    })

    await connectAndOpen(client, transport)

    const huge = 9_007_199_254_740_992 // 2^53 (not a safe integer)

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 11n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 2,
                    date: 101n,
                    update: {
                      oneofKind: "chatHasNewUpdates",
                      chatHasNewUpdates: { chatId: 10n, updateSeq: huge as any, peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } } },
                    },
                  }),
                ],
              },
            },
          },
        },
      }),
    )

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES))
    const rpc = transport.sent.find((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES)
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates rpc")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 12n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: {
              oneofKind: "getUpdates",
              getUpdates: {
                updates: [],
                seq: BigInt(huge),
                date: 0n,
                resultType: GetUpdatesResult_ResultType.SLICE,
                final: false,
              },
            },
          },
        },
      }),
    )

    await waitFor(() => warned > 0)
    expect(client.exportState().lastSeqByChatId?.["10"]).toBe(1)
    await client.close()
  })

  it("GET_UPDATES catch-up aborts when server makes no progress and logs", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1, lastSeqByChatId: { "10": 1 } })
    let warned = 0
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
      logger: { warn: () => warned++ } as any,
    })

    await connectAndOpen(client, transport)

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 11n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 2,
                    date: 101n,
                    update: {
                      oneofKind: "chatHasNewUpdates",
                      chatHasNewUpdates: { chatId: 10n, updateSeq: 5, peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } } },
                    },
                  }),
                ],
              },
            },
          },
        },
      }),
    )

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES))
    const rpc = transport.sent.find((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES)
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates rpc")

    // Return a seq equal to the cursor (startSeq=1) with final=false to trigger the "no progress" guard.
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 12n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: {
              oneofKind: "getUpdates",
              getUpdates: {
                updates: [],
                seq: 1n,
                date: 0n,
                resultType: GetUpdatesResult_ResultType.SLICE,
                final: false,
              },
            },
          },
        },
      }),
    )

    await waitFor(() => warned > 0)
    await client.close()
  })
})
