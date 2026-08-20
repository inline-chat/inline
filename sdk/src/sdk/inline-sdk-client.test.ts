import { describe, expect, it, vi } from "vitest"
import { BotCapability_Kind, ConnectionError_Reason, DialogFollowMode, GetUpdatesResult_ResultType, Method, RpcError_Code, ServerProtocolMessage, SyncSkippedSequence_Reason, Update } from "@inline-chat/protocol/core"
import { InlineSdkClient } from "./inline-sdk-client.js"
import { MockTransport } from "../realtime/mock-transport.js"
import type { InlineSdkState, InlineSdkStateStore } from "./types.js"
import { InlineSdkAuthenticationError } from "./errors.js"

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

const irrelevantSkippedSequences = (after: number, through: number, excluding: number[] = []) => {
  const excluded = new Set(excluding)
  return Array.from({ length: Math.max(0, through - after) }, (_, index) => after + index + 1)
    .filter((seq) => !excluded.has(seq))
    .map((seq) => ({
      seq: BigInt(seq),
      reason: SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET,
    }))
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

class FailingStateStore implements InlineSdkStateStore {
  attempts = 0
  constructor(private readonly initial: InlineSdkState) {}
  async load() {
    return this.initial
  }
  async save() {
    this.attempts++
    throw new Error("state store unavailable")
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

  it("keeps close disconnect-only when a credential owner is configured", async () => {
    const transport = new MockTransport()
    const credentialOwner = {
      beginLogout: vi.fn(),
      clearCredentials: vi.fn(),
      finishLogout: vi.fn(),
    }
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      credentialOwner,
    })
    await connectAndOpen(client, transport)

    await client.close()

    expect(credentialOwner.beginLogout).not.toHaveBeenCalled()
    expect(credentialOwner.clearCredentials).not.toHaveBeenCalled()
    expect(credentialOwner.finishLogout).not.toHaveBeenCalled()
  })

  it("marks logout before RPC and destroys credentials after a lost result", async () => {
    const order: string[] = []
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      rpcTimeoutMs: 10,
      credentialOwner: {
        beginLogout: () => { order.push("begin") },
        clearCredentials: () => { order.push("clear") },
        finishLogout: () => { order.push("finish") },
      },
    })
    await connectAndOpen(client, transport)

    const logout = client.logout()
    await waitFor(() => transport.sent.some(
      (message) => message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.LOG_OUT,
    ))
    expect(order).toEqual(["begin"])
    const logoutCall = transport.sent.find(
      (message) => message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.LOG_OUT,
    )
    if (!logoutCall || logoutCall.body.oneofKind !== "rpcCall") throw new Error("missing logout RPC")
    expect(logoutCall.body.rpcCall.input.oneofKind).toBe("logOut")

    await expect(logout).resolves.toEqual({ remoteOutcome: "commitUnknown" })
    expect(order).toEqual(["begin", "clear", "finish"])
    expect(transport.state).toBe("idle")
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
    expect(client.getDiagnostics().started).toBe(false)

    const retry = client.connect()
    await transport.connect()
    await waitFor(() => transport.sent.some((message) => message.body.oneofKind === "connectionInit"))
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 1n,
      body: { oneofKind: "connectionOpen", connectionOpen: {} },
    }))
    await expect(retry).resolves.toBeUndefined()
    await client.close()
  })

  it("removes the connect AbortSignal listener after open", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })
    const controller = new AbortController()

    const connected = client.connect(controller.signal)
    await transport.connect()
    await waitFor(() => transport.sent.some((message) => message.body.oneofKind === "connectionInit"))
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 1n,
      body: { oneofKind: "connectionOpen", connectionOpen: {} },
    }))
    await connected

    controller.abort()
    await Promise.resolve()

    expect(client.getDiagnostics().started).toBe(true)
    expect(transport.state).toBe("connected")
    await client.close()
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

  it("rejects and latches a terminal authentication failure", async () => {
    const transport = new MockTransport()
    const onAuthenticationError = vi.fn()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "deleted-user-token",
      transport,
      onAuthenticationError,
    })

    const connectPromise = client.connect()
    await transport.connect()
    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "connectionInit"))
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 1n,
        body: {
          oneofKind: "connectionError",
          connectionError: { reason: ConnectionError_Reason.UNAUTHORIZED },
        },
      }),
    )

    const error = await connectPromise.catch((cause) => cause)
    expect(error).toBeInstanceOf(InlineSdkAuthenticationError)
    expect(error).toMatchObject({
      code: "UNAUTHORIZED",
      reason: ConnectionError_Reason.UNAUTHORIZED,
      terminal: true,
    })
    expect(onAuthenticationError).toHaveBeenCalledOnce()
    expect(transport.state).toBe("idle")
    await expect(client.connect()).rejects.toBe(error)
  })

  it("stops an established client when its session is revoked", async () => {
    const transport = new MockTransport()
    const onAuthenticationError = vi.fn()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "revoked-session-token",
      transport,
      onAuthenticationError,
    })

    await connectAndOpen(client, transport)
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 2n,
        body: {
          oneofKind: "connectionError",
          connectionError: { reason: ConnectionError_Reason.SESSION_REVOKED },
        },
      }),
    )
    await waitFor(() => onAuthenticationError.mock.calls.length === 1)

    expect(transport.state).toBe("idle")
    expect(client.getDiagnostics()).toMatchObject({
      started: false,
      authenticationErrorCode: "SESSION_REVOKED",
    })
    await expect(client.connect()).rejects.toMatchObject({
      code: "SESSION_REVOKED",
    })
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

  it("restores declared bot capabilities after reconnect", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })
    await connectAndOpen(client, transport)

    const registration = client.setMyBotCapabilities({
      capabilities: [{ kind: BotCapability_Kind.CHAT_SETTINGS, version: 1 }],
    })
    await waitFor(() => transport.sent.some(
      (message) => message.body.oneofKind === "rpcCall"
        && message.body.rpcCall.method === Method.SET_MY_BOT_CAPABILITIES,
    ))
    const initial = transport.sent.find(
      (message) => message.body.oneofKind === "rpcCall"
        && message.body.rpcCall.method === Method.SET_MY_BOT_CAPABILITIES,
    )
    if (!initial || initial.body.oneofKind !== "rpcCall") throw new Error("missing capability registration")
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 2n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: initial.id,
          result: {
            oneofKind: "setMyBotCapabilities",
            setMyBotCapabilities: { capabilities: [{ kind: BotCapability_Kind.CHAT_SETTINGS, version: 1 }] },
          },
        },
      },
    }))
    await registration

    const callsBeforeReconnect = transport.sent.filter(
      (message) => message.body.oneofKind === "rpcCall"
        && message.body.rpcCall.method === Method.SET_MY_BOT_CAPABILITIES,
    ).length
    await transport.reconnect()
    await transport.connect()
    await waitFor(() => transport.sent.filter(
      (message) => message.body.oneofKind === "connectionInit",
    ).length >= 2)
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 3n,
      body: { oneofKind: "connectionOpen", connectionOpen: {} },
    }))
    await waitFor(() => transport.sent.filter(
      (message) => message.body.oneofKind === "rpcCall"
        && message.body.rpcCall.method === Method.SET_MY_BOT_CAPABILITIES,
    ).length === callsBeforeReconnect + 1)

    await client.close()
  })

  it("does not start an overlapping capability registration on reconnect", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })
    await connectAndOpen(client, transport)

    const registration = client.setMyBotCapabilities({
      capabilities: [{ kind: BotCapability_Kind.CHAT_SETTINGS, version: 1 }],
    })
    await waitFor(() => transport.sent.some(
      (message) => message.body.oneofKind === "rpcCall"
        && message.body.rpcCall.method === Method.SET_MY_BOT_CAPABILITIES,
    ))
    const first = transport.sent.find(
      (message) => message.body.oneofKind === "rpcCall"
        && message.body.rpcCall.method === Method.SET_MY_BOT_CAPABILITIES,
    )
    if (!first || first.body.oneofKind !== "rpcCall") throw new Error("missing capability registration")

    await transport.reconnect()
    await transport.connect()
    await waitFor(() => transport.sent.filter(
      (message) => message.body.oneofKind === "connectionInit",
    ).length >= 2)
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 3n,
      body: { oneofKind: "connectionOpen", connectionOpen: {} },
    }))
    await waitFor(() => transport.sent.filter(
      (message) => message.body.oneofKind === "rpcCall"
        && message.body.rpcCall.method === Method.SET_MY_BOT_CAPABILITIES,
    ).length >= 2)
    const capabilityCalls = transport.sent.filter(
      (message) => message.body.oneofKind === "rpcCall"
        && message.body.rpcCall.method === Method.SET_MY_BOT_CAPABILITIES,
    )
    expect(new Set(capabilityCalls.map((message) => message.id)).size).toBe(1)

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 4n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: first.id,
          result: {
            oneofKind: "setMyBotCapabilities",
            setMyBotCapabilities: { capabilities: [{ kind: BotCapability_Kind.CHAT_SETTINGS, version: 1 }] },
          },
        },
      },
    }))
    await registration
    await client.close()
  })

  it("flushes a newer capability declaration after an in-flight registration", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })
    await connectAndOpen(client, transport)

    const firstRegistration = client.setMyBotCapabilities({
      capabilities: [{ kind: BotCapability_Kind.CHAT_SETTINGS, version: 1 }],
    })
    await waitFor(() => transport.sent.some(
      (message) => message.body.oneofKind === "rpcCall"
        && message.body.rpcCall.method === Method.SET_MY_BOT_CAPABILITIES,
    ))
    const first = transport.sent.find(
      (message) => message.body.oneofKind === "rpcCall"
        && message.body.rpcCall.method === Method.SET_MY_BOT_CAPABILITIES,
    )
    if (!first || first.body.oneofKind !== "rpcCall") throw new Error("missing capability registration")

    const secondRegistration = client.setMyBotCapabilities({ capabilities: [] })
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 3n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: first.id,
          result: {
            oneofKind: "setMyBotCapabilities",
            setMyBotCapabilities: { capabilities: [{ kind: BotCapability_Kind.CHAT_SETTINGS, version: 1 }] },
          },
        },
      },
    }))

    await waitFor(() => transport.sent.filter(
      (message) => message.body.oneofKind === "rpcCall"
        && message.body.rpcCall.method === Method.SET_MY_BOT_CAPABILITIES,
    ).length === 2)
    const calls = transport.sent.filter(
      (message) => message.body.oneofKind === "rpcCall"
        && message.body.rpcCall.method === Method.SET_MY_BOT_CAPABILITIES,
    )
    const second = calls[1]
    if (!second || second.body.oneofKind !== "rpcCall") throw new Error("missing refreshed capability registration")
    if (second.body.rpcCall.input.oneofKind !== "setMyBotCapabilities") throw new Error("missing capability input")
    expect(second.body.rpcCall.input.setMyBotCapabilities.capabilities).toEqual([])

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 4n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: second.id,
          result: {
            oneofKind: "setMyBotCapabilities",
            setMyBotCapabilities: { capabilities: [] },
          },
        },
      },
    }))
    await Promise.all([firstRegistration, secondRegistration])
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
                chat: {
                  id: 7n,
                  title: "Test thread",
                  parentChatId: 3n,
                  parentMessageId: 99n,
                  lastMsgId: 100n,
                  number: 12,
                  untitled: true,
                },
                dialog: {
                  chatId: 7n,
                  followMode: DialogFollowMode.FOLLOWING,
                },
                pinnedMessageIds: [],
              },
            },
          },
        },
      }),
    )

    await expect(p).resolves.toEqual({
      chatId: 7n,
      parentChatId: 3n,
      parentMessageId: 99n,
      lastMsgId: 100n,
      dialogFollowMode: DialogFollowMode.FOLLOWING,
      number: 12,
      title: "Test thread",
      untitled: true,
    })
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

  it("clearChatHistory() accepts chatId target", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const p = client.clearChatHistory({ chatId: 7, keepLastDays: 30, deleteReplyThreads: true })

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall"))
    const rpc = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.CLEAR_CHAT_HISTORY,
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing clearChatHistory rpc")
    expect(rpc.body.rpcCall.input.oneofKind).toBe("clearChatHistory")
    if (rpc.body.rpcCall.input.oneofKind !== "clearChatHistory") throw new Error("missing clearChatHistory")
    const payload = rpc.body.rpcCall.input.clearChatHistory
    expect(payload.target.oneofKind).toBe("peerId")
    if (payload.target.oneofKind === "peerId") {
      expect(payload.target.peerId.type.oneofKind).toBe("chat")
      if (payload.target.peerId.type.oneofKind === "chat") {
        expect(payload.target.peerId.type.chat.chatId).toBe(7n)
      }
    }
    expect(payload.keepLastDays).toBe(30)
    expect(payload.deleteReplyThreads).toBe(true)

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 6n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: {
              oneofKind: "clearChatHistory",
              clearChatHistory: {
                updates: [],
              },
            },
          },
        },
      }),
    )

    await expect(p).resolves.toBeUndefined()
    await client.close()
  })

  it("clearChatHistory() accepts spaceId target", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const p = client.clearChatHistory({ spaceId: 9, keepLastDays: 0 })

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall"))
    const rpc = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.CLEAR_CHAT_HISTORY,
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing clearChatHistory rpc")
    if (rpc.body.rpcCall.input.oneofKind !== "clearChatHistory") throw new Error("missing clearChatHistory")
    const payload = rpc.body.rpcCall.input.clearChatHistory
    expect(payload.target.oneofKind).toBe("spaceId")
    if (payload.target.oneofKind === "spaceId") {
      expect(payload.target.spaceId).toBe(9n)
    }
    expect(payload.keepLastDays).toBe(0)
    expect(payload.deleteReplyThreads).toBe(false)

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 7n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: {
              oneofKind: "clearChatHistory",
              clearChatHistory: {
                updates: [],
              },
            },
          },
        },
      }),
    )

    await expect(p).resolves.toBeUndefined()
    await client.close()
  })

  it("clearChatHistory() rejects invalid targets and ranges", async () => {
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport: new MockTransport(),
    })

    await expect(client.clearChatHistory({ chatId: 7, spaceId: 9, keepLastDays: 0 } as any)).rejects.toThrow(
      /exactly one of `chatId`, `userId`, or `spaceId`/,
    )
    await expect(client.clearChatHistory({ keepLastDays: 0 } as any)).rejects.toThrow(
      /exactly one of `chatId`, `userId`, or `spaceId`/,
    )
    await expect(client.clearChatHistory({ chatId: 7, keepLastDays: -1 })).rejects.toThrow(/keepLastDays/)
    await expect(client.clearChatHistory({ chatId: 7, keepLastDays: 36_501 })).rejects.toThrow(/keepLastDays/)
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
    expect(rpc.body.rpcCall.input.sendMessage.randomId).not.toBe(0n)

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 3n,
        body: { oneofKind: "rpcResult", rpcResult: { reqMsgId: rpc.id, result: { oneofKind: "sendMessage", sendMessage: { updates: [] } } } },
      }),
    )

    await expect(p).resolves.toEqual({ messageId: null })
    await client.close()
  })

  it("sendMessage() keeps its application idempotency key across reconnect replay", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })
    await connectAndOpen(client, transport)

    const pending = client.sendMessage({ chatId: 7, text: "once", randomId: 42n })
    await waitFor(() => transport.sent.filter(
      (message) => message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.SEND_MESSAGE,
    ).length === 1)

    await transport.emitMessage(ServerProtocolMessage.create({
      body: { oneofKind: "connectionError", connectionError: {} },
    }))
    await waitFor(() => transport.state === "connecting", 1_500)
    await transport.connect()
    await waitFor(() => transport.sent.filter((message) => message.body.oneofKind === "connectionInit").length >= 2)
    await transport.emitMessage(ServerProtocolMessage.create({
      body: { oneofKind: "connectionOpen", connectionOpen: {} },
    }))

    await waitFor(() => transport.sent.filter(
      (message) => message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.SEND_MESSAGE,
    ).length === 2)
    const sends = transport.sent.filter(
      (message) => message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.SEND_MESSAGE,
    )
    const replayed = sends[1]
    if (!replayed || replayed.body.oneofKind !== "rpcCall" ||
        replayed.body.rpcCall.input.oneofKind !== "sendMessage") {
      throw new Error("missing replayed sendMessage")
    }
    expect(replayed.body.rpcCall.input.sendMessage.randomId).toBe(42n)

    await transport.emitMessage(ServerProtocolMessage.create({
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: replayed.id,
          result: { oneofKind: "sendMessage", sendMessage: { updates: [] } },
        },
      },
    }))
    await expect(pending).resolves.toEqual({ messageId: null })
    await client.close()
  })

  it("sendMessage() rejects invalid application idempotency keys before dispatch", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })
    await connectAndOpen(client, transport)

    await expect(client.sendMessage({ chatId: 7, text: "bad", randomId: 0n })).rejects.toThrow(/randomId/)
    await expect(client.sendMessage({ chatId: 7, text: "bad", randomId: 1n << 63n })).rejects.toThrow(/randomId/)
    expect(transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.SEND_MESSAGE,
    )).toBe(false)
    await client.close()
  })

  it("sendMessage() serializes an explicit false Markdown parsing flag", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const p = client.sendMessage({ userId: 42, text: "hi", parseMarkdown: false })

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
    expect(rpc.body.rpcCall.input.sendMessage.parseMarkdown).toBe(false)

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 3n,
        body: { oneofKind: "rpcResult", rpcResult: { reqMsgId: rpc.id, result: { oneofKind: "sendMessage", sendMessage: { updates: [] } } } },
      }),
    )

    await expect(p).resolves.toEqual({ messageId: null })
    await client.close()
  })

  it("sendMessage() supports media payloads", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const p = client.sendMessage({
      chatId: 7,
      text: "caption",
      media: { kind: "photo", photoId: 99 },
    })

    await waitFor(() => transport.sent.filter((m) => m.body.oneofKind === "rpcCall").length > 0)
    const rpc = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.SEND_MESSAGE,
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing rpc")
    if (rpc.body.rpcCall.input.oneofKind !== "sendMessage") throw new Error("missing sendMessage")
    const payload = rpc.body.rpcCall.input.sendMessage
    expect(payload.message).toBe("caption")
    expect(payload.parseMarkdown).toBeUndefined()
    expect(payload.media?.media.oneofKind).toBe("photo")
    if (payload.media?.media.oneofKind === "photo") {
      expect(payload.media.media.photo.photoId).toBe(99n)
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

  it("sendMessage() supports video and document media payloads", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const p1 = client.sendMessage({
      chatId: 7,
      media: { kind: "video", videoId: 55 },
    })
    await waitFor(() => transport.sent.filter((m) => m.body.oneofKind === "rpcCall").length > 0)
    const rpc1 = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.SEND_MESSAGE,
    )
    if (!rpc1 || rpc1.body.oneofKind !== "rpcCall") throw new Error("missing rpc1")
    if (rpc1.body.rpcCall.input.oneofKind !== "sendMessage") throw new Error("missing sendMessage")
    expect(rpc1.body.rpcCall.input.sendMessage.media?.media.oneofKind).toBe("video")
    if (rpc1.body.rpcCall.input.sendMessage.media?.media.oneofKind === "video") {
      expect(rpc1.body.rpcCall.input.sendMessage.media.media.video.videoId).toBe(55n)
    }
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 30n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: { reqMsgId: rpc1.id, result: { oneofKind: "sendMessage", sendMessage: { updates: [] } } },
        },
      }),
    )
    await expect(p1).resolves.toEqual({ messageId: null })

    const p2 = client.sendMessage({
      userId: 42,
      media: { kind: "document", documentId: 77 },
    })
    await waitFor(() => transport.sent.filter((m) => m.body.oneofKind === "rpcCall").length > 1)
    const rpcCalls = transport.sent.filter((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.SEND_MESSAGE)
    const rpc2 = rpcCalls[rpcCalls.length - 1]
    if (!rpc2 || rpc2.body.oneofKind !== "rpcCall") throw new Error("missing rpc2")
    if (rpc2.body.rpcCall.input.oneofKind !== "sendMessage") throw new Error("missing sendMessage2")
    expect(rpc2.body.rpcCall.input.sendMessage.media?.media.oneofKind).toBe("document")
    if (rpc2.body.rpcCall.input.sendMessage.media?.media.oneofKind === "document") {
      expect(rpc2.body.rpcCall.input.sendMessage.media.media.document.documentId).toBe(77n)
    }
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 31n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: { reqMsgId: rpc2.id, result: { oneofKind: "sendMessage", sendMessage: { updates: [] } } },
        },
      }),
    )
    await expect(p2).resolves.toEqual({ messageId: null })
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

    await expect(
      client.sendMessage({
        chatId: 7,
      } as any),
    ).rejects.toThrow(/provide `text` and\/or `media`/)

    await expect(
      client.sendMessage({
        chatId: 7,
        media: { kind: "photo", photoId: 9 },
        parseMarkdown: true,
      } as any),
    ).rejects.toThrow(/parseMarkdown.*non-empty `text`/)

    await expect(
      client.sendMessage({
        chatId: 7,
        media: { kind: "photo", photoId: 9 },
        entities: {},
      } as any),
    ).rejects.toThrow(/entities.*non-empty `text`/)

    await client.close()
  })

  describe.skip("legacy HTTP upload compatibility", () => {
  it("uploadFile() sends multipart payload and returns ids", async () => {
    const fetchMock = vi.fn(async (input: unknown, init?: RequestInit) => {
      expect(String(input)).toBe("https://api.inline.chat/v1/uploadFile")
      const body = init?.body
      if (!(body instanceof FormData)) throw new Error("missing form-data body")
      expect(body.get("type")).toBe("photo")
      expect(body.get("file")).toBeInstanceOf(Blob)
      return new Response(
        JSON.stringify({
          ok: true,
          result: {
            fileUniqueId: "INP_123",
            photoId: 77,
          },
        }),
        {
          status: 200,
          headers: { "content-type": "application/json" },
        },
      )
    })
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      fetch: fetchMock as any,
    })

    const result = await client.uploadFile({
      type: "photo",
      file: new Uint8Array([1, 2, 3]),
      fileName: "photo.png",
      contentType: "image/png",
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(result).toEqual({
      fileUniqueId: "INP_123",
      photoId: 77n,
    })
  })

  it("uploadFile() preserves custom base path before /v1/uploadFile", async () => {
    const fetchMock = vi.fn(async (input: unknown) => {
      expect(String(input)).toBe("https://example.com/custom-prefix/v1/uploadFile")
      return new Response(
        JSON.stringify({
          ok: true,
          result: {
            fileUniqueId: "INP_path",
            photoId: 44,
          },
        }),
        {
          status: 200,
          headers: { "content-type": "application/json" },
        },
      )
    })
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://example.com/custom-prefix",
      fetch: fetchMock as any,
    })

    const result = await client.uploadFile({
      type: "photo",
      file: new Uint8Array([1]),
    })

    expect(result).toEqual({
      fileUniqueId: "INP_path",
      photoId: 44n,
    })
  })

  it("uploadFile() accepts Blob input and preserves matching blob content type", async () => {
    const sourceBlob = new Blob([new Uint8Array([1, 2, 3])], { type: "image/png" })
    const fetchMock = vi.fn(async (_input: unknown, init?: RequestInit) => {
      const body = init?.body
      if (!(body instanceof FormData)) throw new Error("missing form-data body")
      const file = body.get("file")
      if (!(file instanceof Blob)) throw new Error("missing file blob")
      expect(file.type).toBe("image/png")
      return new Response(
        JSON.stringify({
          ok: true,
          result: {
            fileUniqueId: "INP_blob",
            photoId: 12,
          },
        }),
        {
          status: 200,
          headers: { "content-type": "application/json" },
        },
      )
    })
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      fetch: fetchMock as any,
    })

    const result = await client.uploadFile({
      type: "photo",
      file: sourceBlob,
      contentType: "image/png",
    })

    expect(result).toEqual({
      fileUniqueId: "INP_blob",
      photoId: 12n,
    })
  })

  it("uploadFile() sanitizes path-like filenames to a leaf name", async () => {
    const fetchMock = vi.fn(async (_input: unknown, init?: RequestInit) => {
      const body = init?.body
      if (!(body instanceof FormData)) throw new Error("missing form-data body")
      const file = body.get("file")
      if (!(file instanceof File)) throw new Error("missing file")
      expect(file.name).toBe("latest-download.jpeg")
      return new Response(
        JSON.stringify({
          ok: true,
          result: {
            fileUniqueId: "INP_name",
            photoId: 5,
          },
        }),
        {
          status: 200,
          headers: { "content-type": "application/json" },
        },
      )
    })
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      fetch: fetchMock as any,
    })

    const result = await client.uploadFile({
      type: "photo",
      file: new Uint8Array([1, 2, 3]),
      fileName: "/workspace/openclaw/tmp/latest-download.jpeg?token=abc",
      contentType: "image/jpeg",
    })

    expect(result).toEqual({
      fileUniqueId: "INP_name",
      photoId: 5n,
    })
  })

  it("uploadFile() supports thumbnail uploads for video", async () => {
    const fetchMock = vi.fn(async (_input: unknown, init?: RequestInit) => {
      const body = init?.body
      if (!(body instanceof FormData)) throw new Error("missing form-data body")
      expect(body.get("type")).toBe("video")
      expect(body.get("thumbnail")).toBeInstanceOf(Blob)
      expect(body.get("width")).toBe("640")
      expect(body.get("height")).toBe("360")
      expect(body.get("duration")).toBe("12")
      return new Response(
        JSON.stringify({
          ok: true,
          result: {
            fileUniqueId: "INV_thumb",
            videoId: "9001",
          },
        }),
        {
          status: 200,
          headers: { "content-type": "application/json" },
        },
      )
    })
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      fetch: fetchMock as any,
    })

    const result = await client.uploadFile({
      type: "video",
      file: new Uint8Array([0, 1]),
      thumbnail: new Uint8Array([2, 3]),
      width: 640,
      height: 360,
      duration: 12,
    })
    expect(result).toEqual({
      fileUniqueId: "INV_thumb",
      videoId: 9001n,
    })
  })

  it("uploadFile() supplies fallback metadata for video uploads", async () => {
    const fetchMock = vi.fn(async (_input: unknown, init?: RequestInit) => {
      const body = init?.body
      if (!(body instanceof FormData)) throw new Error("missing form-data body")
      expect(body.get("type")).toBe("video")
      expect(body.get("width")).toBe("1280")
      expect(body.get("height")).toBe("720")
      expect(body.get("duration")).toBe("1")
      return new Response(
        JSON.stringify({
          ok: true,
          result: {
            fileUniqueId: "INV_123",
            videoId: 88,
          },
        }),
        {
          status: 200,
          headers: { "content-type": "application/json" },
        },
      )
    })
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      fetch: fetchMock as any,
    })

    const result = await client.uploadFile({
      type: "video",
      file: new Uint8Array([0, 1]),
      fileName: "clip.mp4",
      contentType: "video/mp4",
    })

    expect(result).toEqual({
      fileUniqueId: "INV_123",
      videoId: 88n,
    })
  })

  it("uploadFile() surfaces API errors", async () => {
    const fetchMock = vi.fn(async () => {
      return new Response(
        JSON.stringify({
          ok: false,
          description: "Invalid file type",
        }),
        {
          status: 400,
          headers: { "content-type": "application/json" },
        },
      )
    })
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      fetch: fetchMock as any,
    })

    await expect(
      client.uploadFile({
        type: "document",
        file: new Uint8Array([1]),
        fileName: "doc.txt",
      }),
    ).rejects.toThrow(/Invalid file type/)
  })

  it("uploadFile() rejects invalid video metadata inputs", async () => {
    const fetchMock = vi.fn()
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      fetch: fetchMock as any,
    })

    await expect(
      client.uploadFile({
        type: "video",
        file: new Uint8Array([1]),
        width: 0,
      }),
    ).rejects.toThrow(/width must be a positive integer/)
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it("uploadFile() handles non-json upstream failures", async () => {
    const fetchMock = vi.fn(async () => {
      return new Response("upstream timeout", {
        status: 504,
        headers: { "content-type": "text/plain" },
      })
    })
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      fetch: fetchMock as any,
    })

    await expect(
      client.uploadFile({
        type: "photo",
        file: new Uint8Array([1]),
      }),
    ).rejects.toThrow(/upstream timeout/)
  })

  it("uploadFile() handles invalid json responses", async () => {
    const fetchMock = vi.fn(async () => {
      return new Response("{ not-json", {
        status: 500,
        headers: { "content-type": "application/json" },
      })
    })
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      fetch: fetchMock as any,
    })

    await expect(
      client.uploadFile({
        type: "photo",
        file: new Uint8Array([1]),
      }),
    ).rejects.toThrow(/status 500/)
  })

  it("uploadFile() rejects malformed success payloads", async () => {
    const fetchMock = vi.fn(async () => {
      return new Response(
        JSON.stringify({
          ok: true,
          result: {},
        }),
        {
          status: 200,
          headers: { "content-type": "application/json" },
        },
      )
    })
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      fetch: fetchMock as any,
    })

    await expect(
      client.uploadFile({
        type: "document",
        file: new Uint8Array([1]),
      }),
    ).rejects.toThrow(/missing fileUniqueId/)
  })

  it("uploadFile() rejects invalid id payload in success envelope", async () => {
    const fetchMock = vi.fn(async () => {
      return new Response(
        JSON.stringify({
          ok: true,
          result: {
            fileUniqueId: "INP_id",
            documentId: "invalid-id",
          },
        }),
        {
          status: 200,
          headers: { "content-type": "application/json" },
        },
      )
    })
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      fetch: fetchMock as any,
    })

    await expect(
      client.uploadFile({
        type: "document",
        file: new Uint8Array([1]),
      }),
    ).rejects.toThrow(/invalid documentId/)
  })

  it("uploadFile() handles API errors without description", async () => {
    const fetchMock = vi.fn(async () => {
      return new Response(
        JSON.stringify({
          ok: false,
        }),
        {
          status: 400,
          headers: { "content-type": "application/json" },
        },
      )
    })
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      fetch: fetchMock as any,
    })

    await expect(
      client.uploadFile({
        type: "photo",
        file: new Uint8Array([1]),
      }),
    ).rejects.toThrow(/request failed with status 400/)
  })

  it("uploadFile() rejects non-safe numeric ids in success payload", async () => {
    const fetchMock = vi.fn(async () => {
      return new Response(
        JSON.stringify({
          ok: true,
          result: {
            fileUniqueId: "INP_big",
            documentId: Number.MAX_SAFE_INTEGER + 1,
          },
        }),
        {
          status: 200,
          headers: { "content-type": "application/json" },
        },
      )
    })
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      fetch: fetchMock as any,
    })

    await expect(
      client.uploadFile({
        type: "document",
        file: new Uint8Array([1]),
      }),
    ).rejects.toThrow(/invalid documentId/)
  })

  it("uploadFile() rejects unsupported id value types", async () => {
    const fetchMock = vi.fn(async () => {
      return new Response(
        JSON.stringify({
          ok: true,
          result: {
            fileUniqueId: "INP_obj",
            documentId: { value: 1 },
          },
        }),
        {
          status: 200,
          headers: { "content-type": "application/json" },
        },
      )
    })
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      fetch: fetchMock as any,
    })

    await expect(
      client.uploadFile({
        type: "document",
        file: new Uint8Array([1]),
      }),
    ).rejects.toThrow(/invalid documentId/)
  })
  })

  it("uploadFile() uses native resumable RPCs and returns typed media", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      transport,
    })
    await connectAndOpen(client, transport)

    const upload = client.uploadFile({
      type: "photo",
      file: new Uint8Array([1, 2, 3]),
      fileName: "photo.png",
      contentType: "image/png",
    })
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.CREATE_UPLOAD))
    const create = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.CREATE_UPLOAD)
    if (!create || create.body.oneofKind !== "rpcCall" ||
        create.body.rpcCall.input.oneofKind !== "createUpload") throw new Error("missing createUpload")
    expect(create.body.rpcCall.input.createUpload.byteCount).toBe(3n)
    expect(create.body.rpcCall.input.createUpload.sha256).toHaveLength(32)
    const uploadId = new Uint8Array(16).fill(7)
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 10n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: create.id,
          result: {
            oneofKind: "createUpload",
            createUpload: { uploadId, partSize: 524_288, partCount: 1, expiresAt: 1n, acceptedParts: [] },
          },
        },
      },
    }))

    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.SAVE_UPLOAD_PART))
    const save = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.SAVE_UPLOAD_PART)
    if (!save || save.body.oneofKind !== "rpcCall" ||
        save.body.rpcCall.input.oneofKind !== "saveUploadPart") throw new Error("missing saveUploadPart")
    expect(save.body.rpcCall.input.saveUploadPart.data).toEqual(new Uint8Array([1, 2, 3]))
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 11n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: save.id,
          result: { oneofKind: "saveUploadPart", saveUploadPart: { alreadyPresent: false } },
        },
      },
    }))

    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.FINISH_UPLOAD))
    const finish = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.FINISH_UPLOAD)
    if (!finish || finish.body.oneofKind !== "rpcCall") throw new Error("missing finishUpload")
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 12n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: finish.id,
          result: {
            oneofKind: "finishUpload",
            finishUpload: {
              state: {
                oneofKind: "complete",
                complete: {
                  fileUniqueId: "INP_native",
                  media: { oneofKind: "photo", photo: { id: 77n } },
                },
              },
            },
          },
        },
      },
    }))

    await expect(upload).resolves.toEqual({ fileUniqueId: "INP_native", photoId: 77n })
    await client.close()
  })

  it("keeps an upload-scoped unauthenticated error from poisoning the session", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      token: "test-token",
      baseUrl: "https://api.inline.chat",
      transport,
    })
    await connectAndOpen(client, transport)

    const upload = client.uploadFile({
      type: "photo",
      file: new Uint8Array([1, 2, 3]),
      fileName: "photo.png",
      contentType: "image/png",
    })
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.CREATE_UPLOAD))
    const create = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.CREATE_UPLOAD)
    if (!create || create.body.oneofKind !== "rpcCall") throw new Error("missing createUpload")
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 10n,
      body: {
        oneofKind: "rpcError",
        rpcError: {
          reqMsgId: create.id,
          errorCode: RpcError_Code.UNAUTHENTICATED,
          code: 401,
          message: "upload owner is unavailable",
        },
      },
    }))

    await expect(upload).rejects.toThrow("upload owner is unavailable")
    expect(client.getDiagnostics()).toMatchObject({
      started: true,
      authenticationErrorCode: null,
    })

    const getMe = client.getMe()
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_ME))
    const getMeCall = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_ME)
    if (!getMeCall || getMeCall.body.oneofKind !== "rpcCall") throw new Error("missing getMe")
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 11n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: getMeCall.id,
          result: { oneofKind: "getMe", getMe: { user: { id: 42n } } },
        },
      },
    }))
    await expect(getMe).resolves.toEqual({ userId: 42n })
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

  it("marks the chat bucket degraded and reconnects when the event count budget overflows", async () => {
    const transport = new MockTransport()
    const reconnect = vi.spyOn(transport, "reconnect")
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 50n,
      body: {
        oneofKind: "message",
        message: {
          payload: {
            oneofKind: "update",
            update: {
              updates: Array.from({ length: 257 }, (_, index) => Update.create({
                seq: index + 1,
                date: BigInt(index + 1),
                update: {
                  oneofKind: "participantAdd",
                  participantAdd: { chatId: 10n, participant: { userId: BigInt(index + 1), date: BigInt(index + 1) } },
                },
              })),
            },
          },
        },
      },
    }))

    await waitFor(() => client.getSyncStatus().state === "degraded")
    expect(client.getDiagnostics().started).toBe(true)
    expect(client.exportState().lastSeqByChatId).toBeUndefined()
    expect(client.getSyncStatus().degradedBuckets).toMatchObject([{ kind: "chat", chatId: 10n }])
    expect(reconnect).toHaveBeenCalled()
    await client.close()
  })

  it("marks the user bucket degraded and reconnects when the event byte budget overflows", async () => {
    const transport = new MockTransport()
    const reconnect = vi.spyOn(transport, "reconnect")
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 51n,
      body: {
        oneofKind: "message",
        message: {
          payload: {
            oneofKind: "update",
            update: {
              updates: [Update.create({
                seq: 1,
                date: 1n,
                update: {
                  oneofKind: "messageActionInvoked",
                  messageActionInvoked: {
                    interactionId: 1n,
                    chatId: 10n,
                    messageId: 2n,
                    actorUserId: 3n,
                    actionId: "large",
                    data: new Uint8Array(8 * 1024 * 1024),
                  },
                },
              })],
            },
          },
        },
      },
    }))

    await waitFor(() => client.getSyncStatus().state === "degraded")
    expect(client.getDiagnostics().started).toBe(true)
    expect(client.exportState().lastUserSeq).toBeUndefined()
    expect(client.getSyncStatus().degradedBuckets).toMatchObject([{ kind: "user" }])
    expect(reconnect).toHaveBeenCalled()
    await client.close()
  })

  it("resolves a legacy chat cursor peer before catch-up and persists it", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1, lastSeqByChatId: { "10": 1 } })
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
    })

    await connectAndOpen(client, transport)
    // Legacy peer resolution remains targeted to a bucket that needs repair;
    // opening the SDK does not enumerate every persisted bucket.
    void (client as any).requestCatchUpForDegradedBucket({ kind: "chat", chatId: 10n })
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_CHAT,
    ))
    const getChat = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_CHAT,
    )
    if (!getChat || getChat.body.oneofKind !== "rpcCall") throw new Error("missing legacy peer lookup")

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 53n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: getChat.id,
          result: {
            oneofKind: "getChat",
            getChat: {
              chat: {
                id: 10n,
                title: "Legacy DM",
                peerId: { type: { oneofKind: "user", user: { userId: 42n } } },
              },
            },
          },
        },
      },
    }))

    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" &&
      message.body.rpcCall.method === Method.GET_UPDATES &&
      message.body.rpcCall.input.oneofKind === "getUpdates" &&
      message.body.rpcCall.input.getUpdates.bucket?.type.oneofKind === "chat",
    ))
    const getUpdates = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" &&
      message.body.rpcCall.method === Method.GET_UPDATES &&
      message.body.rpcCall.input.oneofKind === "getUpdates" &&
      message.body.rpcCall.input.getUpdates.bucket?.type.oneofKind === "chat",
    )
    if (!getUpdates || getUpdates.body.oneofKind !== "rpcCall") throw new Error("missing legacy chat catch-up")
    if (getUpdates.body.rpcCall.input.oneofKind !== "getUpdates") throw new Error("missing getUpdates input")
    expect(getUpdates.body.rpcCall.input.getUpdates.bucket?.type.chat?.peerId?.type.oneofKind).toBe("user")

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 54n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: getUpdates.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [],
              seq: 1n,
              date: 0n,
              resultType: GetUpdatesResult_ResultType.SLICE,
              final: true,
            },
          },
        },
      },
    }))

    await waitFor(() => client.getSyncStatus().state === "live")
    expect(client.exportState().chatPeerByChatId).toEqual({ "10": { kind: "user", id: "42" } })
    await client.close()
  })

  it("keeps a legacy chat bucket degraded when peer resolution fails", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({ version: 1, lastSeqByChatId: { "10": 1 } }),
    })

    await connectAndOpen(client, transport)
    void (client as any).requestCatchUpForDegradedBucket({ kind: "chat", chatId: 10n })
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_CHAT,
    ))
    const getChat = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_CHAT,
    )
    if (!getChat || getChat.body.oneofKind !== "rpcCall") throw new Error("missing legacy peer lookup")

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 54n,
      body: {
        oneofKind: "rpcError",
        rpcError: {
          reqMsgId: getChat.id,
          errorCode: RpcError_Code.INTERNAL_ERROR,
          message: "lookup unavailable",
          code: 500,
        },
      },
    }))

    await waitFor(() => client.getSyncStatus().state === "degraded")
    expect(client.getDiagnostics().started).toBe(true)
    expect(client.getSyncStatus().degradedBuckets).toMatchObject([{ kind: "chat", chatId: 10n }])
    expect(transport.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" &&
      message.body.rpcCall.method === Method.GET_UPDATES &&
      message.body.rpcCall.input.oneofKind === "getUpdates" &&
      message.body.rpcCall.input.getUpdates.bucket?.type.oneofKind === "chat",
    )).toHaveLength(0)
    await client.close()
  })

  it("accounts for an unprojected durable update without stranding the chat bucket", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({
        version: 1,
        lastSeqByChatId: { "10": 1 },
        chatPeerByChatId: { "10": { kind: "chat", id: "10" } },
      }),
    })

    await connectAndOpen(client, transport)
    const iter = client.events()[Symbol.asyncIterator]()
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 55n,
      body: {
        oneofKind: "message",
        message: {
          payload: {
            oneofKind: "update",
            update: {
              updates: [
                Update.create({
                  seq: 2,
                  date: 2n,
                  // Durable in the bucket, but not yet owned by this SDK's event reducer.
                  update: { oneofKind: "messageAttachment", messageAttachment: { chatId: 10n } } as any,
                }),
                Update.create({
                  seq: 3,
                  date: 3n,
                  update: {
                    oneofKind: "participantAdd",
                    participantAdd: { chatId: 10n, participant: { userId: 42n, date: 3n } },
                  },
                }),
              ],
            },
          },
        },
      },
    }))

    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    ))
    const catchUp = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    )
    if (!catchUp || catchUp.body.oneofKind !== "rpcCall") throw new Error("missing unprojected catch-up")
    expect(client.getSyncStatus().state).toBe("syncing")
    const pendingEvent = iter.next()
    const prematureEvent = await Promise.race([
      pendingEvent.then(() => true),
      new Promise<false>((resolve) => setTimeout(() => resolve(false), 20)),
    ])
    expect(prematureEvent).toBe(false)
    expect(client.exportState().lastSeqByChatId?.["10"]).toBe(1)

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 56n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: catchUp.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [
                Update.create({
                  seq: 2,
                  date: 2n,
                  update: { oneofKind: "messageAttachment", messageAttachment: { chatId: 10n } } as any,
                }),
                Update.create({
                  seq: 3,
                  date: 3n,
                  update: {
                    oneofKind: "participantAdd",
                    participantAdd: { chatId: 10n, participant: { userId: 42n, date: 3n } },
                  },
                }),
              ],
              seq: 3n,
              date: 3n,
              resultType: GetUpdatesResult_ResultType.SLICE,
              final: true,
              skippedSequences: [],
            },
          },
        },
      },
    }))

    const event = await pendingEvent
    expect(event.done).toBe(false)
    expect(event.value.kind).toBe("chat.participant.add")
    const next = iter.next()
    await waitFor(() => client.exportState().lastSeqByChatId?.["10"] === 3)
    await waitFor(() => client.getSyncStatus().state === "live")
    expect(client.getSyncStatus()).toEqual({ state: "live", degradedBuckets: [] })
    await client.close()
    await next
  })

  it("keeps transient compose updates lossy without fencing the durable chat cursor", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)
    const iter = client.events()[Symbol.asyncIterator]()
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 56n,
      body: {
        oneofKind: "message",
        message: {
          payload: {
            oneofKind: "update",
            update: {
              updates: [
                Update.create({
                  // Transient compose updates intentionally have no durable sequence.
                  update: {
                    oneofKind: "updateComposeAction",
                    updateComposeAction: {
                      userId: 42n,
                      peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
                      action: 1,
                    },
                  },
                }),
                Update.create({
                  seq: 3,
                  date: 3n,
                  update: {
                    oneofKind: "participantAdd",
                    participantAdd: { chatId: 10n, participant: { userId: 42n, date: 3n } },
                  },
                }),
              ],
            },
          },
        },
      },
    }))

    const event = await iter.next()
    expect(event.done).toBe(false)
    expect(event.value.kind).toBe("chat.participant.add")
    const next = iter.next()
    await waitFor(() => client.exportState().lastSeqByChatId?.["10"] === 3)
    expect(client.getSyncStatus().degradedBuckets).toEqual([])
    await client.close()
    await next
  })

  it("treats zero chat and space hints as authoritative fetch-to-latest requests", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({
        version: 1,
        lastSeqByChatId: { "10": 4 },
        lastSeqBySpaceId: { "20": 7 },
        chatPeerByChatId: { "10": { kind: "chat", id: "10" } },
      }),
    })

    await connectAndOpen(client, transport)
    void (client as any).handleUpdate(Update.create({
      update: {
        oneofKind: "chatHasNewUpdates",
        chatHasNewUpdates: {
          chatId: 10n,
          updateSeq: 0,
          peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
        },
      },
    }), { source: "live" })
    void (client as any).handleUpdate(Update.create({
      update: {
        oneofKind: "spaceHasNewUpdates",
        spaceHasNewUpdates: { spaceId: 20n, updateSeq: 0 },
      },
    }), { source: "live" })

    await waitFor(() => transport.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    ).length === 2)
    const calls = transport.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    )
    expect(calls).toHaveLength(2)
    for (const call of calls) {
      if (call.body.oneofKind !== "rpcCall" || call.body.rpcCall.input.oneofKind !== "getUpdates") {
        throw new Error("missing GET_UPDATES input")
      }
      // The generated scalar defaults to zero; zero is the wire sentinel for
      // an omitted upper bound and the server fetches through its latest cursor.
      expect(call.body.rpcCall.input.getUpdates.seqEnd).toBe(0n)
    }
    await client.close()
  })

  it("accepts chatSkipPts as an explicit cursor-only chat catch-up record", async () => {
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport: new MockTransport(),
    })
    const accepted = await (client as any).acceptCatchUpUpdates([
      Update.create({
        seq: 2,
        date: 100n,
        update: { oneofKind: "chatSkipPts", chatSkipPts: { chatId: 10n } },
      }),
    ], "chat", { kind: "chat", chatId: 10n })

    expect(accepted).toBe(true)
  })

  it("keeps user-owned dialog updates from fencing an unrelated DM chat bucket", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({
        version: 1,
        lastSeqByChatId: { "10": 1 },
        chatPeerByChatId: { "10": { kind: "user", id: "42" } },
      }),
    })

    await connectAndOpen(client, transport)
    const iter = client.events()[Symbol.asyncIterator]()
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 57n,
      body: {
        oneofKind: "message",
        message: {
          payload: {
            oneofKind: "update",
            update: {
              updates: [
                Update.create({
                  seq: 2,
                  date: 2n,
                  // This dialog update is durable, but has no SDK reducer yet.
                  update: {
                    oneofKind: "dialogArchived",
                    dialogArchived: {
                      peerId: { type: { oneofKind: "user", user: { userId: 42n } } },
                    },
                  } as any,
                }),
                Update.create({
                  seq: 2,
                  date: 3n,
                  update: {
                    oneofKind: "participantAdd",
                    participantAdd: { chatId: 10n, participant: { userId: 42n, date: 3n } },
                  },
                }),
              ],
            },
          },
        },
      },
    }))

    const event = await iter.next()
    expect(event.done).toBe(false)
    expect(event.value.kind).toBe("chat.participant.add")
    const next = iter.next()
    await waitFor(() => client.exportState().lastSeqByChatId?.["10"] === 2)
    expect(client.exportState().lastSeqByChatId?.["10"]).toBe(2)
    expect(client.getSyncStatus()).toEqual({ state: "syncing", degradedBuckets: [] })

    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" &&
      message.body.rpcCall.method === Method.GET_UPDATES &&
      message.body.rpcCall.input.oneofKind === "getUpdates" &&
      message.body.rpcCall.input.getUpdates.bucket?.type.oneofKind === "user",
    ))
    const userCatchUp = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" &&
      message.body.rpcCall.method === Method.GET_UPDATES &&
      message.body.rpcCall.input.oneofKind === "getUpdates" &&
      message.body.rpcCall.input.getUpdates.bucket?.type.oneofKind === "user",
    )
    if (!userCatchUp || userCatchUp.body.oneofKind !== "rpcCall") throw new Error("missing user catch-up")
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 58n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: userCatchUp.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [Update.create({
                seq: 2,
                date: 2n,
                update: {
                  oneofKind: "dialogArchived",
                  dialogArchived: {
                    peerId: { type: { oneofKind: "user", user: { userId: 42n } } },
                  },
                } as any,
              })],
              seq: 2n,
              date: 2n,
              resultType: GetUpdatesResult_ResultType.SLICE,
              final: true,
              skippedSequences: irrelevantSkippedSequences(0, 2, [2]),
            },
          },
        },
      },
    }))
    await waitFor(() => client.exportState().lastUserSeq === 2)
    await waitFor(() => client.getSyncStatus().state === "live")
    await client.close()
    await next
  })

  it("invokeUncheckedRaw() bypasses input/result validation for known methods", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    // GET_ME normally expects getMe input; unchecked should still send mismatched input.
    const p = client.invokeUncheckedRaw(Method.GET_ME, { oneofKind: "sendMessage", sendMessage: {} } as any)

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_ME))
    const rpc = transport.sent.find((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_ME)
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
    const getUpdatesCall = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES,
    )
    if (!getUpdatesCall || getUpdatesCall.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates call")
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
                skippedSequences: irrelevantSkippedSequences(1, 5, [4]),
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

    expect(client.exportState().lastSeqByChatId?.["10"]).toBe(1)
    const next = iter.next()
    await waitFor(() => client.exportState().lastSeqByChatId?.["10"] === 5)
    await client.close()
    await next

    // State persisted (close() flushes).
    expect(store.saved.length).toBeGreaterThan(0)
    expect(store.loaded?.lastSeqByChatId?.["10"]).toBe(5)
  })

  it("withholds a gapped live update until the durable bucket range is acknowledged", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({
        version: 1,
        lastSeqByChatId: { "10": 1 },
        chatPeerByChatId: { "10": { kind: "chat", id: "10" } },
      }),
    })

    await connectAndOpen(client, transport)
    const iter = client.events()[Symbol.asyncIterator]()
    const pendingEvent = iter.next()

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 60n,
      body: {
        oneofKind: "message",
        message: {
          payload: {
            oneofKind: "update",
            update: {
              updates: [Update.create({
                seq: 3,
                date: 103n,
                update: {
                  oneofKind: "newMessage",
                  newMessage: {
                    message: {
                      id: 30n,
                      chatId: 10n,
                      fromId: 2n,
                      peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
                      out: false,
                      date: 103n,
                    },
                  },
                },
              })],
            },
          },
        },
      },
    }))

    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    ))
    const catchUp = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    )
    if (!catchUp || catchUp.body.oneofKind !== "rpcCall" ||
        catchUp.body.rpcCall.input.oneofKind !== "getUpdates") {
      throw new Error("missing gap catch-up")
    }
    expect(catchUp.body.rpcCall.input.getUpdates.startSeq).toBe(1n)
    expect(catchUp.body.rpcCall.input.getUpdates.seqEnd).toBe(3n)
    expect(client.exportState().lastSeqByChatId?.["10"]).toBe(1)

    const prematureEvent = await Promise.race([
      pendingEvent.then(() => true),
      new Promise<false>((resolve) => setTimeout(() => resolve(false), 20)),
    ])
    expect(prematureEvent).toBe(false)

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 61n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: catchUp.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [Update.create({
                seq: 3,
                date: 103n,
                update: {
                  oneofKind: "newMessage",
                  newMessage: {
                    message: {
                      id: 30n,
                      chatId: 10n,
                      fromId: 2n,
                      peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
                      out: false,
                      date: 103n,
                    },
                  },
                },
              })],
              seq: 3n,
              date: 103n,
              resultType: GetUpdatesResult_ResultType.SLICE,
              final: true,
              skippedSequences: irrelevantSkippedSequences(1, 3, [3]),
            },
          },
        },
      },
    }))

    const recovered = await pendingEvent
    expect(recovered.done).toBe(false)
    expect(recovered.value.kind).toBe("message.new")
    if (recovered.value.kind === "message.new") expect(recovered.value.message.id).toBe(30n)
    expect(client.exportState().lastSeqByChatId?.["10"]).toBe(1)

    const next = iter.next()
    await waitFor(() => client.exportState().lastSeqByChatId?.["10"] === 3)
    expect(client.getSyncStatus()).toEqual({ state: "live", degradedBuckets: [] })
    await client.close()
    await next
  })

  it("admits contiguous same-bucket live updates while acknowledgements are pending", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({ version: 1, lastSeqByChatId: { "10": 1 } }),
    })

    await connectAndOpen(client, transport)
    const iter = client.events()[Symbol.asyncIterator]()
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 62n,
      body: {
        oneofKind: "message",
        message: {
          payload: {
            oneofKind: "update",
            update: {
              updates: [2, 3].map((seq) => Update.create({
                seq,
                date: BigInt(100 + seq),
                update: {
                  oneofKind: "participantAdd",
                  participantAdd: { chatId: 10n, participant: { userId: BigInt(40 + seq), date: 100n } },
                },
              })),
            },
          },
        },
      },
    }))

    const first = await iter.next()
    expect(first.value.kind).toBe("chat.participant.add")
    const second = await iter.next()
    expect(second.value.kind).toBe("chat.participant.add")
    expect(client.exportState().lastSeqByChatId?.["10"]).toBe(2)
    expect(transport.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    )).toHaveLength(0)

    const next = iter.next()
    await waitFor(() => client.exportState().lastSeqByChatId?.["10"] === 3)
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 63n,
      body: {
        oneofKind: "message",
        message: {
          payload: {
            oneofKind: "update",
            update: {
              updates: [Update.create({
                seq: 2,
                date: 104n,
                update: {
                  oneofKind: "participantDelete",
                  participantDelete: { chatId: 10n, userId: 42n },
                },
              })],
            },
          },
        },
      },
    }))
    const staleWasDelivered = await Promise.race([
      next.then(() => true),
      new Promise<false>((resolve) => setTimeout(() => resolve(false), 20)),
    ])
    expect(staleWasDelivered).toBe(false)
    await client.close()
    await next
  })

  it("emits chat participant events and commits their cursor only after application acknowledgement", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)
    const iter = client.events()[Symbol.asyncIterator]()

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
                    update: {
                      oneofKind: "participantAdd",
                      participantAdd: {
                        chatId: 10n,
                        participant: { userId: 42n, date: 100n },
                      },
                    },
                  }),
                  Update.create({
                    seq: 3,
                    date: 101n,
                    update: {
                      oneofKind: "participantDelete",
                      participantDelete: {
                        chatId: 10n,
                        userId: 42n,
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

    const add = await iter.next()
    expect(add.value.kind).toBe("chat.participant.add")
    if (add.value.kind === "chat.participant.add") {
      expect(add.value.chatId).toBe(10n)
      expect(add.value.participant?.userId).toBe(42n)
    }

    const del = await iter.next()
    expect(del.value.kind).toBe("chat.participant.delete")
    if (del.value.kind === "chat.participant.delete") {
      expect(del.value.chatId).toBe(10n)
      expect(del.value.userId).toBe(42n)
    }

    expect(client.exportState().lastSeqByChatId?.["10"]).toBe(2)
    const next = iter.next()
    await waitFor(() => client.exportState().lastSeqByChatId?.["10"] === 3)
    expect(client.exportState().lastSeqByChatId?.["10"]).toBe(3)
    await client.close()
    await next
  })

  it("performs reconnect catch-up for a DM chat without stored seq", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1 })
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
    })

    await connectAndOpen(client, transport)

    const iter = client.events()[Symbol.asyncIterator]()

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 21n,
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
                      chatHasNewUpdates: {
                        chatId: 10n,
                        updateSeq: 5,
                        peerId: { type: { oneofKind: "user", user: { userId: 42n } } },
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

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES))
    const rpc = transport.sent.find((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES)
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates rpc")
    if (rpc.body.rpcCall.input.oneofKind !== "getUpdates") throw new Error("missing getUpdates input")
    expect(rpc.body.rpcCall.input.getUpdates.startSeq).toBe(0n)
    expect(rpc.body.rpcCall.input.getUpdates.bucket?.type.oneofKind).toBe("chat")
    expect(rpc.body.rpcCall.input.getUpdates.bucket?.type.chat?.peerId?.type.oneofKind).toBe("user")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 22n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: {
              oneofKind: "getUpdates",
              getUpdates: {
                updates: [
                  Update.create({
                    seq: 5,
                    date: 102n,
                    update: {
                      oneofKind: "newMessage",
                      newMessage: {
                        message: {
                          id: 99n,
                          chatId: 10n,
                          fromId: 42n,
                          peerId: { type: { oneofKind: "user", user: { userId: 42n } } },
                          out: false,
                          date: 102n,
                        },
                      },
                    },
                  }),
                ],
                seq: 5n,
                date: 102n,
                resultType: GetUpdatesResult_ResultType.SLICE,
                final: true,
                skippedSequences: irrelevantSkippedSequences(0, 5, [5]),
              },
            },
          },
        },
      }),
    )

    const ev1 = await iter.next()
    expect(ev1.done).toBe(false)
    expect(ev1.value.kind).toBe("chat.hasUpdates")

    const ev2 = await iter.next()
    expect(ev2.done).toBe(false)
    expect(ev2.value.kind).toBe("message.new")
    if (ev2.value.kind === "message.new") {
      expect(ev2.value.chatId).toBe(10n)
      expect(ev2.value.message.id).toBe(99n)
    }

    expect(client.exportState().lastSeqByChatId?.["10"]).toBeUndefined()
    const next = iter.next()
    await waitFor(() => client.exportState().lastSeqByChatId?.["10"] === 5)
    await client.close()
    await next
  })

  it("does not stall live delivery behind chat catch-up", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({
        version: 1,
        lastSeqByChatId: { "10": 1, "20": 2 },
        chatPeerByChatId: {
          "10": { kind: "chat", id: "10" },
          "20": { kind: "chat", id: "20" },
        },
      }),
    })

    await connectAndOpen(client, transport)

    const iter = client.events()[Symbol.asyncIterator]()

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 30n,
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
                      chatHasNewUpdates: {
                        chatId: 10n,
                        updateSeq: 5,
                        peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
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

    const ev1 = await iter.next()
    expect(ev1.done).toBe(false)
    expect(ev1.value.kind).toBe("chat.hasUpdates")

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES))
    const getUpdatesCall = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES,
    )
    if (!getUpdatesCall || getUpdatesCall.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates call")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 31n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 3,
                    date: 102n,
                    update: {
                      oneofKind: "newMessage",
                      newMessage: {
                        message: {
                          id: 77n,
                          chatId: 20n,
                          fromId: 8n,
                          peerId: { type: { oneofKind: "chat", chat: { chatId: 20n } } },
                          out: false,
                          date: 102n,
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

    const liveEvent = await Promise.race([
      iter.next(),
      new Promise<{ timeout: true }>((resolve) => setTimeout(() => resolve({ timeout: true }), 25)),
    ])

    expect("timeout" in liveEvent).toBe(false)
    if (!("timeout" in liveEvent)) {
      expect(liveEvent.done).toBe(false)
      expect(liveEvent.value.kind).toBe("message.new")
      if (liveEvent.value.kind === "message.new") {
        expect(liveEvent.value.chatId).toBe(20n)
        expect(liveEvent.value.message.id).toBe(77n)
      }
    }

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 32n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: getUpdatesCall.id,
            result: {
              oneofKind: "getUpdates",
              getUpdates: {
                updates: [],
                seq: 5n,
                date: 103n,
                resultType: GetUpdatesResult_ResultType.SLICE,
                final: true,
              },
            },
          },
        },
      }),
    )

    await client.close()
  })

  it("keeps live delivery running when catch-up RPC fails", async () => {
    const transport = new MockTransport()
    let warned = 0
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({
        version: 1,
        lastSeqByChatId: { "10": 1, "20": 2 },
        chatPeerByChatId: {
          "10": { kind: "chat", id: "10" },
          "20": { kind: "chat", id: "20" },
        },
      }),
      logger: { warn: () => warned++ } as any,
    })

    await connectAndOpen(client, transport)

    const iter = client.events()[Symbol.asyncIterator]()

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 40n,
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
                      chatHasNewUpdates: {
                        chatId: 10n,
                        updateSeq: 5,
                        peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
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

    const ev1 = await iter.next()
    expect(ev1.done).toBe(false)
    expect(ev1.value.kind).toBe("chat.hasUpdates")

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES))
    const getUpdatesCall = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES,
    )
    if (!getUpdatesCall || getUpdatesCall.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates call")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 41n,
        body: {
          oneofKind: "rpcError",
          rpcError: {
            reqMsgId: getUpdatesCall.id,
            errorCode: RpcError_Code.INTERNAL_ERROR,
            message: "catch-up failed",
            code: 500,
          },
        },
      }),
    )

    await waitFor(() => warned > 0)

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 42n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 3,
                    date: 102n,
                    update: {
                      oneofKind: "newMessage",
                      newMessage: {
                        message: {
                          id: 88n,
                          chatId: 20n,
                          fromId: 9n,
                          peerId: { type: { oneofKind: "chat", chat: { chatId: 20n } } },
                          out: false,
                          date: 102n,
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

    const ev2 = await Promise.race([
      iter.next(),
      new Promise<{ timeout: true }>((resolve) => setTimeout(() => resolve({ timeout: true }), 25)),
    ])

    expect("timeout" in ev2).toBe(false)
    if (!("timeout" in ev2)) {
      expect(ev2.done).toBe(false)
      expect(ev2.value.kind).toBe("message.new")
      if (ev2.value.kind === "message.new") {
        expect(ev2.value.chatId).toBe(20n)
        expect(ev2.value.message.id).toBe(88n)
      }
    }

    await client.close()
  })

  it("supports sendTyping, updates dateCursor when GET_UPDATES_STATE is empty, and skips deleteMessages without chat peer", async () => {
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
            result: {
              oneofKind: "getUpdatesState",
              getUpdatesState: { date: 500n, updatesFound: false } as any,
            },
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

  it("covers state save scheduling and replays a retained backlog in bounded slices", async () => {
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
    const iter = client.events()[Symbol.asyncIterator]()

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

    await iter.next()
    await iter.next()
    const pendingEvent = iter.next()
    await Promise.resolve()
    await Promise.resolve()
    expect(client.exportState().lastSeqByChatId?.["10"]).toBe(3)

    // Let the save timer fire; save stays in-flight until we resolve it.
    await vi.advanceTimersByTimeAsync(250)
    expect(saveCalls).toBe(1)
    expect(saveResolve).not.toBeNull()

    // While save is in-flight, force another save flush path by closing.
    const closing = client.close()
    // Unblock save
    saveResolve?.()
    await closing
    await pendingEvent

    vi.useRealTimers()

    // Now cover the current server's TOO_LONG meaning: history is retained, but
    // the first requested difference is larger than one bounded response.
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
                      chatHasNewUpdates: { chatId: 10n, updateSeq: 1002, peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } } },
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
                seq: 1002n,
                date: 222n,
                // RESULT_TYPE_TOO_LONG
                resultType: GetUpdatesResult_ResultType.TOO_LONG,
              },
            },
          },
        },
      }),
    )

    await waitFor(() => transport2.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES
    ).length >= 2)
    const replay1 = transport2.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES
    ).at(1)
    if (!replay1 || replay1.body.oneofKind !== "rpcCall") throw new Error("missing first retained replay slice")
    if (replay1.body.rpcCall.input.oneofKind !== "getUpdates") throw new Error("missing first replay input")
    expect(replay1.body.rpcCall.input.getUpdates.startSeq).toBe(1n)
    expect(replay1.body.rpcCall.input.getUpdates.seqEnd).toBe(1001n)
    expect(client2.exportState().lastSeqByChatId?.["10"]).toBe(1)

    await transport2.emitMessage(ServerProtocolMessage.create({
      id: 13n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: replay1.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [],
              seq: 1001n,
              date: 221n,
              resultType: GetUpdatesResult_ResultType.EMPTY,
              final: true,
              skippedSequences: irrelevantSkippedSequences(1, 1001),
            },
          },
        },
      },
    }))

    await waitFor(() => transport2.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES
    ).length >= 3)
    const replay2 = transport2.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES
    ).at(2)
    if (!replay2 || replay2.body.oneofKind !== "rpcCall") throw new Error("missing second retained replay slice")
    if (replay2.body.rpcCall.input.oneofKind !== "getUpdates") throw new Error("missing second replay input")
    expect(replay2.body.rpcCall.input.getUpdates.startSeq).toBe(1001n)
    expect(replay2.body.rpcCall.input.getUpdates.seqEnd).toBe(1002n)

    await transport2.emitMessage(ServerProtocolMessage.create({
      id: 14n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: replay2.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [],
              seq: 1002n,
              date: 222n,
              resultType: GetUpdatesResult_ResultType.EMPTY,
              final: true,
              skippedSequences: irrelevantSkippedSequences(1001, 1002),
            },
          },
        },
      },
    }))

    await waitFor(() => client2.exportState().lastSeqByChatId?.["10"] === 1002)
    expect(client2.exportState().dateCursor).toBeUndefined()
    expect(client2.getSyncStatus()).toEqual({ state: "live", degradedBuckets: [] })
    expect(warned).toBe(0)
    await client2.close()
  })

  it("persists a newer cursor dirtied while an older state snapshot is in flight", async () => {
    let releaseFirstSave: (() => void) | null = null
    const firstSave = new Promise<void>((resolve) => { releaseFirstSave = resolve })
    const saved: InlineSdkState[] = []
    const store: InlineSdkStateStore = {
      async load() { return { version: 1 } },
      async save(next) {
        saved.push(next)
        if (saved.length === 1) await firstSave
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

    const internal = client as any
    internal.bumpChatSeq(10n, 2)
    await waitFor(() => saved.length === 1, 1_000)
    internal.bumpChatSeq(10n, 3)
    releaseFirstSave?.()
    await internal.flushStateSave()

    expect(saved).toHaveLength(2)
    expect(saved[1]?.lastSeqByChatId?.["10"]).toBe(3)
    await client.close()
  })

  it("degrades instead of looping when retained-history replay stops making progress", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({ version: 1, lastSeqBySpaceId: { "20": 1 } }),
    })

    await connectAndOpen(client, transport)
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 19n,
      body: {
        oneofKind: "message",
        message: { payload: { oneofKind: "update", update: { updates: [Update.create({
          update: {
            oneofKind: "spaceHasNewUpdates",
            spaceHasNewUpdates: { spaceId: 20n, updateSeq: 1002 },
          },
        })] } } },
      },
    }))
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES
    ))
    const first = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES
    )
    if (!first || first.body.oneofKind !== "rpcCall") throw new Error("missing first getUpdates request")
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 20n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: first.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [],
              seq: 1002n,
              date: 302n,
              resultType: GetUpdatesResult_ResultType.TOO_LONG,
              final: false,
            },
          },
        },
      },
    }))
    await waitFor(() => transport.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES
    ).length === 2)
    const replay = transport.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES
    )[1]
    if (!replay || replay.body.oneofKind !== "rpcCall") throw new Error("missing retained replay request")
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 21n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: replay.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [],
              seq: 1n,
              date: 302n,
              resultType: GetUpdatesResult_ResultType.EMPTY,
              final: true,
            },
          },
        },
      },
    }))

    await waitFor(() => client.getSyncStatus().state === "degraded")
    await new Promise((resolve) => setTimeout(resolve, 25))
    expect(transport.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES
    )).toHaveLength(2)
    expect(client.exportState().lastSeqBySpaceId?.["20"]).toBe(1)
    await client.close()
  })

  it("replays a retained user backlog without requiring a host snapshot callback", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({ version: 1, lastUserSeq: 0 }),
    })

    await connectAndOpen(client, transport)
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" &&
      message.body.rpcCall.method === Method.GET_UPDATES &&
      message.body.rpcCall.input.oneofKind === "getUpdates" &&
      message.body.rpcCall.input.getUpdates.bucket?.type.oneofKind === "user"
    ))
    const calls = () => transport.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" &&
      message.body.rpcCall.method === Method.GET_UPDATES &&
      message.body.rpcCall.input.oneofKind === "getUpdates" &&
      message.body.rpcCall.input.getUpdates.bucket?.type.oneofKind === "user"
    )
    const first = calls()[0]
    if (!first || first.body.oneofKind !== "rpcCall") throw new Error("missing initial user catch-up")
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 22n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: first.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [],
              seq: 1001n,
              date: 303n,
              resultType: GetUpdatesResult_ResultType.TOO_LONG,
              final: false,
            },
          },
        },
      },
    }))

    await waitFor(() => calls().length >= 2)
    const replay1 = calls()[1]
    if (!replay1 || replay1.body.oneofKind !== "rpcCall") throw new Error("missing first user replay slice")
    if (replay1.body.rpcCall.input.oneofKind !== "getUpdates") throw new Error("missing first user replay input")
    expect(replay1.body.rpcCall.input.getUpdates.startSeq).toBe(0n)
    expect(replay1.body.rpcCall.input.getUpdates.seqEnd).toBe(1000n)
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 23n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: replay1.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [],
              seq: 1000n,
              date: 302n,
              resultType: GetUpdatesResult_ResultType.EMPTY,
              final: true,
              skippedSequences: irrelevantSkippedSequences(0, 1000),
            },
          },
        },
      },
    }))

    await waitFor(() => calls().length >= 3)
    const replay2 = calls()[2]
    if (!replay2 || replay2.body.oneofKind !== "rpcCall") throw new Error("missing second user replay slice")
    if (replay2.body.rpcCall.input.oneofKind !== "getUpdates") throw new Error("missing second user replay input")
    expect(replay2.body.rpcCall.input.getUpdates.startSeq).toBe(1000n)
    expect(replay2.body.rpcCall.input.getUpdates.seqEnd).toBe(1001n)
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 24n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: replay2.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [],
              seq: 1001n,
              date: 303n,
              resultType: GetUpdatesResult_ResultType.EMPTY,
              final: true,
              skippedSequences: irrelevantSkippedSequences(1000, 1001),
            },
          },
        },
      },
    }))

    await waitFor(() => client.exportState().lastUserSeq === 1001)
    expect(client.getSyncStatus()).toEqual({ state: "live", degradedBuckets: [] })
    await client.close()
  })

  it("does not advance a catch-up cursor past missing sequence accounting", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({ version: 1, lastSeqByChatId: { "10": 1 } }),
    })

    await connectAndOpen(client, transport)
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 15n,
      body: {
        oneofKind: "message",
        message: { payload: { oneofKind: "update", update: { updates: [Update.create({
          update: {
            oneofKind: "chatHasNewUpdates",
            chatHasNewUpdates: {
              chatId: 10n,
              updateSeq: 3,
              peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
            },
          },
        })] } } },
      },
    }))
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES
    ))
    const rpc = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates request")

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 16n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: rpc.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [],
              seq: 3n,
              date: 300n,
              resultType: GetUpdatesResult_ResultType.EMPTY,
              final: true,
              skippedSequences: [],
            },
          },
        },
      },
    }))

    await waitFor(() => client.getSyncStatus().state === "degraded")
    expect(client.exportState().lastSeqByChatId?.["10"]).toBe(1)
    expect(client.getSyncStatus().degradedBuckets).toMatchObject([{ kind: "chat", chatId: 10n }])
    await client.close()
  })

  it("rejects malformed catch-up envelope variants without moving a cursor", () => {
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport: new MockTransport(),
    })
    const validate = (payload: unknown) => (client as any).validateCatchUpPage(payload, 1, { kind: "user" })

    expect(validate({
      updates: [], seq: 1n, date: 1n, resultType: GetUpdatesResult_ResultType.UNSPECIFIED, skippedSequences: [],
    })).toBeUndefined()
    expect(validate({
      updates: [], seq: 0n, date: 1n, resultType: GetUpdatesResult_ResultType.EMPTY, skippedSequences: [],
    })).toBeUndefined()
    expect(validate({
      updates: [Update.create({})],
      seq: 2n,
      date: 1n,
      resultType: GetUpdatesResult_ResultType.SLICE,
      skippedSequences: [],
    })).toBeUndefined()
    expect(validate({
      updates: [],
      seq: 2n,
      date: 1n,
      resultType: GetUpdatesResult_ResultType.EMPTY,
      skippedSequences: [{ seq: 2n, reason: SyncSkippedSequence_Reason.REASON_UNSPECIFIED }],
    })).toBeUndefined()
    expect(client.exportState().lastUserSeq).toBeUndefined()
  })

  it("routes an explicit snapshot-repair marker through the existing authoritative owner", async () => {
    const transport = new MockTransport()
    const repairs: number[] = []
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({ version: 1, lastSeqBySpaceId: { "20": 1 } }),
      repairUpdatesBucket: async (request) => {
        repairs.push(request.serverSeq)
        return { appliedSeq: request.serverSeq }
      },
    })

    await connectAndOpen(client, transport)
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 17n,
      body: {
        oneofKind: "message",
        message: { payload: { oneofKind: "update", update: { updates: [Update.create({
          update: {
            oneofKind: "spaceHasNewUpdates",
            spaceHasNewUpdates: { spaceId: 20n, updateSeq: 2 },
          },
        })] } } },
      },
    }))
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES
    ))
    const rpc = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates request")

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 18n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: rpc.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [],
              seq: 2n,
              date: 301n,
              resultType: GetUpdatesResult_ResultType.EMPTY,
              final: true,
              skippedSequences: [{
                seq: 2n,
                reason: SyncSkippedSequence_Reason.SNAPSHOT_REPAIR_REQUIRED,
              }],
            },
          },
        },
      },
    }))

    await waitFor(() => client.exportState().lastSeqBySpaceId?.["20"] === 2)
    expect(repairs).toEqual([2])
    expect(client.getSyncStatus()).toEqual({ state: "live", degradedBuckets: [] })
    await client.close()
  })

  it("repairs a retained chat bucket authoritatively before advancing its cursor", async () => {
    const transport = new MockTransport()
    const repairs: Array<{ serverSeq: number; kind: string }> = []
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({
        version: 1,
        lastSeqByChatId: { "10": 1 },
        chatPeerByChatId: { "10": { kind: "user", id: "42" } },
      }),
      repairUpdatesBucket: async (request) => {
        repairs.push({ serverSeq: request.serverSeq, kind: request.bucket.kind })
        return { appliedSeq: request.serverSeq, dateCursor: 222n }
      },
    })

    await connectAndOpen(client, transport)
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 12n,
      body: {
        oneofKind: "message",
        message: {
          payload: {
            oneofKind: "update",
            update: {
              updates: [Update.create({
                seq: 2,
                date: 2n,
                update: {
                  oneofKind: "chatHasNewUpdates",
                  chatHasNewUpdates: {
                    chatId: 10n,
                    updateSeq: 5,
                    peerId: { type: { oneofKind: "user", user: { userId: 42n } } },
                  },
                },
              })],
            },
          },
        },
      },
    }))
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES
    ))
    const rpc = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing targeted repair request")
    if (rpc.body.rpcCall.input.oneofKind !== "getUpdates") throw new Error("missing getUpdates input")
    expect(rpc.body.rpcCall.input.getUpdates.seqEnd).toBe(5n)
    expect(rpc.body.rpcCall.input.getUpdates.bucket?.type.oneofKind).toBe("chat")
    expect(rpc.body.rpcCall.input.getUpdates.bucket?.type.chat?.peerId.type.oneofKind).toBe("user")

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 13n,
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
              resultType: GetUpdatesResult_ResultType.TOO_LONG,
            },
          },
        },
      },
    }))

    await waitFor(() => client.exportState().lastSeqByChatId?.["10"] === 5)
    expect(repairs).toEqual([{ serverSeq: 5, kind: "chat" }])
    expect(client.exportState().dateCursor).toBeUndefined()
    expect(client.getSyncStatus()).toEqual({ state: "live", degradedBuckets: [] })
    await client.close()
  })

  it("advances a bucket cursor past a known update the SDK does not project", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({
        version: 1,
        lastSeqByChatId: { "10": 1 },
        chatPeerByChatId: { "10": { kind: "user", id: "42" } },
      }),
    })

    await connectAndOpen(client, transport)
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 13n,
      body: {
        oneofKind: "message",
        message: {
          payload: {
            oneofKind: "update",
            update: {
              updates: [Update.create({
                seq: 2,
                date: 2n,
                update: {
                  oneofKind: "chatHasNewUpdates",
                  chatHasNewUpdates: {
                    chatId: 10n,
                    updateSeq: 2,
                    peerId: { type: { oneofKind: "user", user: { userId: 42n } } },
                  },
                },
              })],
            },
          },
        },
      },
    }))
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" &&
      message.body.rpcCall.method === Method.GET_UPDATES &&
      message.body.rpcCall.input.oneofKind === "getUpdates" &&
      message.body.rpcCall.input.getUpdates.bucket?.type.oneofKind === "chat",
    ))
    const rpc = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" &&
      message.body.rpcCall.method === Method.GET_UPDATES &&
      message.body.rpcCall.input.oneofKind === "getUpdates" &&
      message.body.rpcCall.input.getUpdates.bucket?.type.oneofKind === "chat",
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing targeted catch-up request")

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 14n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: rpc.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [Update.create({
                seq: 2,
                date: 333n,
                // This durable variant has no SDK event/application owner yet.
                update: { oneofKind: "updateUserStatus", updateUserStatus: {} } as any,
              })],
              seq: 2n,
              date: 333n,
              resultType: GetUpdatesResult_ResultType.SLICE,
              final: true,
            },
          },
        },
      },
    }))

    await waitFor(() => client.exportState().lastSeqByChatId?.["10"] === 2)
    expect(client.exportState().dateCursor).toBeUndefined()
    expect(client.getSyncStatus()).toEqual({ state: "live", degradedBuckets: [] })
    await client.close()
  })

  it("advances a catch-up cursor past an unknown future update kind", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({
        version: 1,
        lastSeqByChatId: { "10": 1 },
        chatPeerByChatId: { "10": { kind: "user", id: "42" } },
      }),
    })

    await connectAndOpen(client, transport)
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 15n,
      body: {
        oneofKind: "message",
        message: {
          payload: {
            oneofKind: "update",
            update: {
              updates: [Update.create({
                seq: 2,
                date: 334n,
                update: { oneofKind: "chatHasNewUpdates", chatHasNewUpdates: {
                  chatId: 10n,
                  updateSeq: 2,
                  peerId: { type: { oneofKind: "user", user: { userId: 42n } } },
                } },
              })],
            },
          },
        },
      },
    }))
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" &&
      message.body.rpcCall.method === Method.GET_UPDATES &&
      message.body.rpcCall.input.oneofKind === "getUpdates" &&
      message.body.rpcCall.input.getUpdates.bucket?.type.oneofKind === "chat",
    ))
    const rpc = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" &&
      message.body.rpcCall.method === Method.GET_UPDATES &&
      message.body.rpcCall.input.oneofKind === "getUpdates" &&
      message.body.rpcCall.input.getUpdates.bucket?.type.oneofKind === "chat",
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing targeted catch-up request")

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 16n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: rpc.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [Update.create({ seq: 2, date: 334n })],
              seq: 2n,
              date: 334n,
              resultType: GetUpdatesResult_ResultType.SLICE,
              final: true,
            },
          },
        },
      },
    }))

    await waitFor(() => client.exportState().lastSeqByChatId?.["10"] === 2)
    expect(client.getSyncStatus()).toEqual({ state: "live", degradedBuckets: [] })
    await client.close()
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
        body: {
          oneofKind: "rpcError",
          rpcError: {
            reqMsgId: call.id,
            errorCode: RpcError_Code.INTERNAL_ERROR,
            message: "nope",
            code: 500,
          },
        },
      }),
    )

    await waitFor(() => warned > 0)
    await client.close()
  })

  it("does not advance dateCursor when GET_UPDATES_STATE found bucket work", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1, dateCursor: 100n })
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
    })

    await connectAndOpen(client, transport)

    await waitFor(() =>
      transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES_STATE),
    )
    const getUpdatesStateCall = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES_STATE,
    )
    if (!getUpdatesStateCall || getUpdatesStateCall.body.oneofKind !== "rpcCall") throw new Error("missing getUpdatesState")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 101n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: getUpdatesStateCall.id,
            result: {
              oneofKind: "getUpdatesState",
              getUpdatesState: { date: 500n, updatesFound: true } as any,
            },
          },
        },
      }),
    )

    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(client.exportState().dateCursor).toBe(100n)
    await client.close()
  })

  it("holds a discovery checkpoint when a hinted bucket cannot be applied", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1, dateCursor: 100n, lastSeqByChatId: { "10": 1 } })
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
    })

    await connectAndOpen(client, transport)
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES_STATE,
    ))
    const stateCall = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES_STATE,
    )
    if (!stateCall || stateCall.body.oneofKind !== "rpcCall") throw new Error("missing getUpdatesState")

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 110n,
      body: {
        oneofKind: "message",
        message: {
          payload: {
            oneofKind: "update",
            update: {
              updates: [Update.create({
                update: {
                  oneofKind: "chatHasNewUpdates",
                  chatHasNewUpdates: {
                    chatId: 10n,
                    updateSeq: 3,
                    peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
                  },
                },
              })],
            },
          },
        },
      },
    }))
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    ))
    const getUpdates = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    )
    if (!getUpdates || getUpdates.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates")

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 111n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: stateCall.id,
          result: { oneofKind: "getUpdatesState", getUpdatesState: { date: 500n, updatesFound: true } as any },
        },
      },
    }))
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 112n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: getUpdates.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [Update.create({
                seq: 2,
                update: { oneofKind: "messageAttachment", messageAttachment: { chatId: 10n } } as any,
              })],
              seq: 3n,
              date: 501n,
              resultType: GetUpdatesResult_ResultType.SLICE,
              final: true,
            },
          },
        },
      },
    }))

    await waitFor(() => client.getSyncStatus().state === "degraded")
    expect(client.exportState().dateCursor).toBe(100n)
    await client.close()
  })

  it("commits a discovery checkpoint after every hinted bucket succeeds", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({
      version: 1,
      dateCursor: 100n,
      lastSeqByChatId: { "10": 1 },
      lastSeqBySpaceId: { "20": 2 },
    })
    const client = new InlineSdkClient({ baseUrl: "https://api.inline.chat", token: "test-token", transport, state: store })

    await connectAndOpen(client, transport)
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES_STATE,
    ))
    const stateCall = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES_STATE,
    )
    if (!stateCall || stateCall.body.oneofKind !== "rpcCall") throw new Error("missing getUpdatesState")

    const hints = [
      Update.create({ update: {
        oneofKind: "chatHasNewUpdates",
        chatHasNewUpdates: { chatId: 10n, updateSeq: 3, peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } } },
      } }),
      Update.create({ update: {
        oneofKind: "spaceHasNewUpdates",
        spaceHasNewUpdates: { spaceId: 20n, updateSeq: 4 },
      } }),
    ]
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 120n,
      body: { oneofKind: "message", message: { payload: { oneofKind: "update", update: { updates: hints } } } },
    }))
    await waitFor(() => transport.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    ).length === 2)
    const getUpdatesCalls = transport.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    )

    for (const [index, call] of getUpdatesCalls.entries()) {
      if (call.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates call")
      await transport.emitMessage(ServerProtocolMessage.create({
        id: BigInt(121 + index),
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: call.id,
            result: {
              oneofKind: "getUpdates",
              getUpdates: {
                updates: [],
                seq: index === 0 ? 3n : 4n,
                date: 500n,
                resultType: GetUpdatesResult_ResultType.EMPTY,
                final: true,
                skippedSequences: index === 0
                  ? irrelevantSkippedSequences(1, 3)
                  : irrelevantSkippedSequences(2, 4),
              },
            },
          },
        },
      }))
    }

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 124n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: stateCall.id,
          result: { oneofKind: "getUpdatesState", getUpdatesState: { date: 500n, updatesFound: true } as any },
        },
      },
    }))
    await waitFor(() => client.exportState().dateCursor === 500n)
    await client.close()
  })

  it("does not let direct live bucket cursor advancement move the discovery date", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({ version: 1, dateCursor: 100n }),
    })

    await connectAndOpen(client, transport)
    ;(client as any).bumpChatSeq(10n, 4, "live")
    expect(client.exportState().lastSeqByChatId?.["10"]).toBe(4)
    expect(client.exportState().dateCursor).toBe(100n)
    await client.close()
  })

  it("does not commit before a wire-ordered hinted update is acknowledged", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1, dateCursor: 100n, lastSeqByChatId: { "10": 1 } })
    const client = new InlineSdkClient({ baseUrl: "https://api.inline.chat", token: "test-token", transport, state: store })
    await connectAndOpen(client, transport)
    const iter = client.events()[Symbol.asyncIterator]()

    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES_STATE,
    ))
    const stateCall = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES_STATE,
    )
    if (!stateCall || stateCall.body.oneofKind !== "rpcCall") throw new Error("missing getUpdatesState")

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 130n,
      body: { oneofKind: "message", message: { payload: { oneofKind: "update", update: { updates: [Update.create({
        update: {
          oneofKind: "chatHasNewUpdates",
          chatHasNewUpdates: { chatId: 10n, updateSeq: 2, peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } } },
        },
      })] } } } },
    }))
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    ))
    const getUpdates = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    )
    if (!getUpdates || getUpdates.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates")

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 131n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: stateCall.id,
          result: { oneofKind: "getUpdatesState", getUpdatesState: { date: 500n, updatesFound: true } as any },
        },
      },
    }))
    // The earlier hint is delivered to the SDK consumer before the durable
    // catch-up update, but the durable update remains unacknowledged here.
    const hintEvent = await iter.next()
    expect(hintEvent.value.kind).toBe("chat.hasUpdates")

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 132n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: getUpdates.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: {
              updates: [Update.create({
                seq: 2,
                update: {
                  oneofKind: "participantAdd",
                  participantAdd: { chatId: 10n, participant: { userId: 20n, date: 501n } },
                },
              })],
              seq: 2n,
              date: 501n,
              resultType: GetUpdatesResult_ResultType.SLICE,
              final: true,
            },
          },
        },
      },
    }))

    await new Promise((resolve) => setTimeout(resolve, 25))
    expect(client.exportState().dateCursor).toBe(100n)
    expect(client.exportState().lastSeqByChatId?.["10"]).toBe(1)
    await client.close()
  })

  it("lets a newer discovery round replace an older pending target", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1, dateCursor: 100n, lastSeqByChatId: { "10": 1 } })
    const client = new InlineSdkClient({ baseUrl: "https://api.inline.chat", token: "test-token", transport, state: store })
    await connectAndOpen(client, transport)
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES_STATE,
    ))
    const stateCalls = () => transport.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES_STATE,
    )
    const oldStateCall = stateCalls()[0]
    if (!oldStateCall || oldStateCall.body.oneofKind !== "rpcCall") throw new Error("missing old discovery")

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 140n,
      body: { oneofKind: "message", message: { payload: { oneofKind: "update", update: { updates: [Update.create({
        update: {
          oneofKind: "chatHasNewUpdates",
          chatHasNewUpdates: { chatId: 10n, updateSeq: 5, peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } } },
        },
      })] } } } },
    }))
    await waitFor(() => transport.sent.filter((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    ).length === 1)
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 141n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: oldStateCall.id,
          result: { oneofKind: "getUpdatesState", getUpdatesState: { date: 500n, updatesFound: true } as any },
        },
      },
    }))

    await new Promise((resolve) => setTimeout(resolve, 10))
    void (client as any).initializeDateCursor()
    await waitFor(() => stateCalls().length === 2)
    const newStateCall = stateCalls()[1]
    if (!newStateCall || newStateCall.body.oneofKind !== "rpcCall") throw new Error("missing new discovery")
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 142n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: newStateCall.id,
          result: { oneofKind: "getUpdatesState", getUpdatesState: { date: 600n, updatesFound: false } as any },
        },
      },
    }))
    await waitFor(() => client.exportState().dateCursor === 600n)

    const oldCatchUp = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    )
    if (!oldCatchUp || oldCatchUp.body.oneofKind !== "rpcCall") throw new Error("missing old catch-up")
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 143n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: oldCatchUp.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: { updates: [], seq: 5n, date: 501n, resultType: GetUpdatesResult_ResultType.SLICE, final: true },
          },
        },
      },
    }))
    expect(client.exportState().dateCursor).toBe(600n)
    await client.close()
  })

  it("ignores late live hints after a discovery round has settled without targets", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1, dateCursor: 100n })
    const client = new InlineSdkClient({ baseUrl: "https://api.inline.chat", token: "test-token", transport, state: store })
    await connectAndOpen(client, transport)
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES_STATE,
    ))
    const stateCall = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES_STATE,
    )
    if (!stateCall || stateCall.body.oneofKind !== "rpcCall") throw new Error("missing getUpdatesState")
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 150n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: stateCall.id,
          result: { oneofKind: "getUpdatesState", getUpdatesState: { date: 500n, updatesFound: true } as any },
        },
      },
    }))
    await new Promise((resolve) => setTimeout(resolve, 10))

    await transport.emitMessage(ServerProtocolMessage.create({
      id: 151n,
      body: { oneofKind: "message", message: { payload: { oneofKind: "update", update: { updates: [Update.create({
        update: { oneofKind: "spaceHasNewUpdates", spaceHasNewUpdates: { spaceId: 20n, updateSeq: 4 } },
      })] } } } },
    }))
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    ))
    const getUpdates = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES,
    )
    if (!getUpdates || getUpdates.body.oneofKind !== "rpcCall") throw new Error("missing late catch-up")
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 152n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: getUpdates.id,
          result: {
            oneofKind: "getUpdates",
            getUpdates: { updates: [], seq: 4n, date: 501n, resultType: GetUpdatesResult_ResultType.SLICE, final: true },
          },
        },
      },
    }))
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(client.exportState().dateCursor).toBe(100n)
    await client.close()
  })

  it("does not treat a failed checkpoint write as a committed discovery date", async () => {
    const transport = new MockTransport()
    const store = new FailingStateStore({ version: 1, dateCursor: 100n })
    const client = new InlineSdkClient({ baseUrl: "https://api.inline.chat", token: "test-token", transport, state: store })
    await connectAndOpen(client, transport)
    await waitFor(() => transport.sent.some((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES_STATE,
    ))
    const stateCall = transport.sent.find((message) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_UPDATES_STATE,
    )
    if (!stateCall || stateCall.body.oneofKind !== "rpcCall") throw new Error("missing getUpdatesState")
    await transport.emitMessage(ServerProtocolMessage.create({
      id: 160n,
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: stateCall.id,
          result: { oneofKind: "getUpdatesState", getUpdatesState: { date: 500n, updatesFound: false } as any },
        },
      },
    }))
    await waitFor(() => store.attempts > 0)
    expect(client.exportState().dateCursor).toBe(100n)
    await client.close()
  })

  it("listener crash rejects connect() and logs", async () => {
    class StopTrackingTransport extends MockTransport {
      stopCalls = 0
      override async stop() {
        this.stopCalls++
        await super.stop()
      }
    }
    const transport = new StopTrackingTransport()
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
    await waitFor(() => transport.stopCalls > 0)
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
    const iter = client.events()[Symbol.asyncIterator]()

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
    await iter.next()
    const pendingEvent = iter.next()
    await Promise.resolve()
    await Promise.resolve()
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
    await pendingEvent
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

    expect(client.exportState().dateCursor).toBeUndefined()
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
                resultType: GetUpdatesResult_ResultType.EMPTY,
                final: false,
                skippedSequences: irrelevantSkippedSequences(1, 3),
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
                resultType: GetUpdatesResult_ResultType.EMPTY,
                final: false,
                skippedSequences: irrelevantSkippedSequences(3, 6),
              },
            },
          },
        },
      }),
    )

    await waitFor(() => client.exportState().lastSeqByChatId?.["10"] === 6)
    expect(client.exportState().dateCursor).toBeUndefined()
    await client.close()
  })

  it("extends same-chat catch-up when a newer live event arrives mid-flight", async () => {
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

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 50n,
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
                      chatHasNewUpdates: {
                        chatId: 10n,
                        updateSeq: 5,
                        peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
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

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES))
    const rpc1 = transport.sent.find((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES)
    if (!rpc1 || rpc1.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates rpc1")
    if (rpc1.body.rpcCall.input.oneofKind !== "getUpdates") throw new Error("missing getUpdates input1")
    expect(rpc1.body.rpcCall.input.getUpdates.startSeq).toBe(1n)
    expect(rpc1.body.rpcCall.input.getUpdates.seqEnd).toBe(5n)
    const hint = await iter.next()
    expect(hint.value.kind).toBe("chat.hasUpdates")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 51n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 8,
                    date: 102n,
                    update: {
                      oneofKind: "newMessage",
                      newMessage: {
                        message: {
                          id: 88n,
                          chatId: 10n,
                          fromId: 2n,
                          peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
                          out: false,
                          date: 102n,
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
    const pendingRecovered = iter.next()

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 52n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc1.id,
            result: {
              oneofKind: "getUpdates",
              getUpdates: {
                updates: [],
                seq: 5n,
                date: 111n,
                resultType: GetUpdatesResult_ResultType.EMPTY,
                final: true,
                skippedSequences: irrelevantSkippedSequences(1, 5),
              },
            },
          },
        },
      }),
    )

    await waitFor(
      () => transport.sent.filter((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES).length >= 2,
    )
    const rpc2 = transport.sent
      .filter((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES)
      .at(1)
    if (!rpc2 || rpc2.body.oneofKind !== "rpcCall") throw new Error("missing getUpdates rpc2")
    if (rpc2.body.rpcCall.input.oneofKind !== "getUpdates") throw new Error("missing getUpdates input2")
    expect(rpc2.body.rpcCall.input.getUpdates.startSeq).toBe(5n)
    expect(rpc2.body.rpcCall.input.getUpdates.seqEnd).toBe(8n)

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 53n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc2.id,
            result: {
              oneofKind: "getUpdates",
              getUpdates: {
                updates: [Update.create({
                  seq: 8,
                  date: 222n,
                  update: {
                    oneofKind: "newMessage",
                    newMessage: {
                      message: {
                        id: 88n,
                        chatId: 10n,
                        fromId: 2n,
                        peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
                        out: false,
                        date: 222n,
                      },
                    },
                  },
                })],
                seq: 8n,
                date: 222n,
                resultType: GetUpdatesResult_ResultType.SLICE,
                final: true,
                skippedSequences: irrelevantSkippedSequences(5, 8, [8]),
              },
            },
          },
        },
      }),
    )

    const recovered = await pendingRecovered
    expect(recovered.value.kind).toBe("message.new")
    if (recovered.value.kind === "message.new") expect(recovered.value.message.id).toBe(88n)
    const next = iter.next()
    await waitFor(() => client.exportState().lastSeqByChatId?.["10"] === 8)
    expect(client.exportState().dateCursor).toBeUndefined()
    await client.close()
    await next
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
                resultType: GetUpdatesResult_ResultType.EMPTY,
                final: true,
                skippedSequences: irrelevantSkippedSequences(1, 5),
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
    expect(client.getSyncStatus().state).toBe("degraded")
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
    expect(client.exportState().lastSeqByChatId?.["10"]).toBe(1)
    expect(client.getSyncStatus().state).toBe("degraded")
    await client.close()
  })

  it("skips catch-up when chat already has in-flight catch-up task", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: new MemoryStateStore({
        version: 1,
        lastSeqByChatId: { "10": 1 },
      }),
    })

    await connectAndOpen(client, transport)

    // Force the in-flight guard branch.
    ;(client as any).catchUpInFlightByChatId.set(10n, Promise.resolve())

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 200n,
        body: {
          oneofKind: "updates",
          updates: {
            updates: [
              Update.create({
                seq: 1,
                date: 10n,
                update: {
                  oneofKind: "chatHasNewUpdates",
                  chatHasNewUpdates: {
                    chatId: 10n,
                    updateSeq: 5,
                    peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
                  },
                },
              }),
            ],
          },
        },
      }),
    )

    await new Promise((r) => setTimeout(r, 25))
    const getUpdatesCalls = transport.sent.filter(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES,
    )
    expect(getUpdatesCalls.length).toBe(0)

    await client.close()
  })

  it("emits message action events and supports invoke/answer action helpers", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)
    const iter = client.events()[Symbol.asyncIterator]()

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 300n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 7,
                    date: 701n,
                    update: {
                      oneofKind: "messageActionInvoked",
                      messageActionInvoked: {
                        interactionId: 99n,
                        chatId: 20n,
                        messageId: 88n,
                        actorUserId: 11n,
                        actionId: "pick",
                        data: new Uint8Array([1, 2, 3]),
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

    const event = await iter.next()
    expect(event.done).toBe(false)
    if (!event.done) {
      expect(event.value.kind).toBe("message.action.invoke")
      if (event.value.kind === "message.action.invoke") {
        expect(event.value.interactionId).toBe(99n)
        expect(event.value.actionId).toBe("pick")
        expect(Array.from(event.value.data)).toEqual([1, 2, 3])
      }
    }

    const invokePromise = client.invokeMessageAction({
      chatId: 20n,
      messageId: 88n,
      actionId: "pick",
    })
    await waitFor(() =>
      transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.INVOKE_MESSAGE_ACTION),
    )
    const invokeCall = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.INVOKE_MESSAGE_ACTION,
    )
    if (!invokeCall || invokeCall.body.oneofKind !== "rpcCall") throw new Error("missing invokeMessageAction")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 301n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: invokeCall.id,
            result: {
              oneofKind: "invokeMessageAction",
              invokeMessageAction: { interactionId: 123n },
            },
          },
        },
      }),
    )

    await expect(invokePromise).resolves.toEqual({ interactionId: 123n })

    const answerPromise = client.answerMessageAction({
      interactionId: 123n,
      ui: {
        kind: {
          oneofKind: "toast",
          toast: {
            text: "ok",
          },
        },
      },
    })
    await waitFor(() =>
      transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.ANSWER_MESSAGE_ACTION),
    )
    const answerCall = transport.sent.find(
      (m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.ANSWER_MESSAGE_ACTION,
    )
    if (!answerCall || answerCall.body.oneofKind !== "rpcCall") throw new Error("missing answerMessageAction")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 302n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: answerCall.id,
            result: {
              oneofKind: "answerMessageAction",
              answerMessageAction: {},
            },
          },
        },
      }),
    )

    await answerPromise
    await client.close()
  })

  it("replays user-bucket message action events after reconnect when lastUserSeq is stored", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1, lastUserSeq: 54 })
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
    })

    await connectAndOpen(client, transport)
    const iter = client.events()[Symbol.asyncIterator]()

    await waitFor(() =>
      transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES),
    )
    const rpc = transport.sent.find(
      (m) =>
        m.body.oneofKind === "rpcCall" &&
        m.body.rpcCall.method === Method.GET_UPDATES &&
        m.body.rpcCall.input.oneofKind === "getUpdates" &&
        m.body.rpcCall.input.getUpdates.bucket?.type.oneofKind === "user",
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing user getUpdates rpc")
    if (rpc.body.rpcCall.input.oneofKind !== "getUpdates") throw new Error("missing getUpdates input")
    expect(rpc.body.rpcCall.input.getUpdates.startSeq).toBe(54n)
    expect(rpc.body.rpcCall.input.getUpdates.bucket?.type.oneofKind).toBe("user")

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 302n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: {
              oneofKind: "getUpdates",
              getUpdates: {
                updates: [
                  Update.create({
                    seq: 55,
                    date: 702n,
                    update: {
                      oneofKind: "messageActionInvoked",
                      messageActionInvoked: {
                        interactionId: 55n,
                        chatId: 20n,
                        messageId: 88n,
                        actorUserId: 11n,
                        actionId: "pick",
                        data: new Uint8Array([4, 5, 6]),
                      },
                    },
                  }),
                ],
                seq: 55n,
                date: 702n,
                resultType: GetUpdatesResult_ResultType.SLICE,
                final: true,
              },
            },
          },
        },
      }),
    )

    const event = await iter.next()
    expect(event.done).toBe(false)
    if (!event.done) {
      expect(event.value.kind).toBe("message.action.invoke")
      if (event.value.kind === "message.action.invoke") {
        expect(event.value.interactionId).toBe(55n)
        expect(event.value.actionId).toBe("pick")
        expect(Array.from(event.value.data)).toEqual([4, 5, 6])
      }
    }

    const next = iter.next()
    await waitFor(() => client.exportState().lastUserSeq === 55)
    expect(client.exportState().lastUserSeq).toBe(55)
    await client.close()
    await next
  })

  it("replays user-bucket participant adds when existing state has no lastUserSeq", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1, dateCursor: 701n })
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
      catchUpUserFromStart: true,
    })

    await connectAndOpen(client, transport)
    const iter = client.events()[Symbol.asyncIterator]()

    await waitFor(() =>
      transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES),
    )
    const rpc = transport.sent.find(
      (m) =>
        m.body.oneofKind === "rpcCall" &&
        m.body.rpcCall.method === Method.GET_UPDATES &&
        m.body.rpcCall.input.oneofKind === "getUpdates" &&
        m.body.rpcCall.input.getUpdates.bucket?.type.oneofKind === "user",
    )
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing user getUpdates rpc")
    if (rpc.body.rpcCall.input.oneofKind !== "getUpdates") throw new Error("missing getUpdates input")
    expect(rpc.body.rpcCall.input.getUpdates.startSeq).toBe(0n)

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 303n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: {
              oneofKind: "getUpdates",
              getUpdates: {
                updates: [
                  Update.create({
                    seq: 1,
                    date: 703n,
                    update: {
                      oneofKind: "participantAdd",
                      participantAdd: {
                        chatId: 20n,
                        participant: { userId: 777n, date: 703n },
                      },
                    },
                  }),
                ],
                seq: 1n,
                date: 703n,
                resultType: GetUpdatesResult_ResultType.SLICE,
                final: true,
              },
            },
          },
        },
      }),
    )

    const event = await iter.next()
    expect(event.done).toBe(false)
    if (!event.done) {
      expect(event.value.kind).toBe("chat.participant.add")
      if (event.value.kind === "chat.participant.add") {
        expect(event.value.chatId).toBe(20n)
        expect(event.value.participant?.userId).toBe(777n)
      }
    }

    const next = iter.next()
    await waitFor(() => client.exportState().lastUserSeq === 1)
    expect(client.exportState().lastSeqByChatId?.["20"]).toBeUndefined()
    await client.close()
    await next
  })

  it("catches up space clear history updates from the space bucket", async () => {
    const transport = new MockTransport()
    const store = new MemoryStateStore({ version: 1, lastSeqBySpaceId: { "20": 1 } })
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
      state: store,
    })

    await connectAndOpen(client, transport)

    const iter = client.events()[Symbol.asyncIterator]()
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 390n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 2,
                    date: 700n,
                    update: {
                      oneofKind: "spaceHasNewUpdates",
                      spaceHasNewUpdates: {
                        spaceId: 20n,
                        updateSeq: 3,
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

    await waitFor(() => transport.sent.some((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES))
    const rpc = transport.sent.find((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES)
    if (!rpc || rpc.body.oneofKind !== "rpcCall") throw new Error("missing space getUpdates rpc")
    if (rpc.body.rpcCall.input.oneofKind !== "getUpdates") throw new Error("missing getUpdates input")
    expect(rpc.body.rpcCall.input.getUpdates.startSeq).toBe(1n)
    // The live space hint targets catch-up through its advertised sequence.
    expect(rpc.body.rpcCall.input.getUpdates.seqEnd).toBe(3n)
    expect(rpc.body.rpcCall.input.getUpdates.bucket?.type.oneofKind).toBe("space")
    expect(rpc.body.rpcCall.input.getUpdates.bucket?.type.space?.spaceId).toBe(20n)

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 391n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: rpc.id,
            result: {
              oneofKind: "getUpdates",
              getUpdates: {
                updates: [
                  Update.create({
                    seq: 3,
                    date: 701n,
                    update: {
                      oneofKind: "clearChatHistory",
                      clearChatHistory: {
                        target: { oneofKind: "spaceId", spaceId: 20n },
                        beforeDate: 600n,
                        deleteReplyThreads: true,
                      },
                    },
                  }),
                ],
                seq: 3n,
                date: 701n,
                resultType: GetUpdatesResult_ResultType.SLICE,
                final: true,
                skippedSequences: irrelevantSkippedSequences(1, 3, [3]),
              },
            },
          },
        },
      }),
    )

    const ev1 = await iter.next()
    expect(ev1.value.kind).toBe("space.hasUpdates")
    const ev2 = await iter.next()
    expect(ev2.value.kind).toBe("space.history.clear")
    if (ev2.value.kind === "space.history.clear") {
      expect(ev2.value.spaceId).toBe(20n)
      expect(ev2.value.beforeDate).toBe(600n)
      expect(ev2.value.deleteReplyThreads).toBe(true)
      expect(ev2.value.seq).toBe(3)
    }

    expect(client.exportState().lastSeqBySpaceId?.["20"]).toBe(1)
    const next = iter.next()
    await waitFor(() => client.exportState().lastSeqBySpaceId?.["20"] === 3)
    await client.close()
    await next
  })

  it("emits clear history events for chat, user, and space targets", async () => {
    const transport = new MockTransport()
    const client = new InlineSdkClient({
      baseUrl: "https://api.inline.chat",
      token: "test-token",
      transport,
    })

    await connectAndOpen(client, transport)

    const iter = client.events()[Symbol.asyncIterator]()
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 400n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 1,
                    date: 10n,
                    update: {
                      oneofKind: "clearChatHistory",
                      clearChatHistory: {
                        target: {
                          oneofKind: "peerId",
                          peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
                        },
                        beforeDate: 5n,
                        deleteReplyThreads: true,
                      },
                    },
                  }),
                  Update.create({
                    seq: 2,
                    date: 11n,
                    update: {
                      oneofKind: "clearChatHistory",
                      clearChatHistory: {
                        target: { oneofKind: "spaceId", spaceId: 20n },
                        deleteReplyThreads: false,
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

    const ev1 = await iter.next()
    expect(ev1.value.kind).toBe("message.history.clear")
    if (ev1.value.kind === "message.history.clear") {
      expect(ev1.value.chatId).toBe(10n)
      expect(ev1.value.beforeDate).toBe(5n)
      expect(ev1.value.deleteReplyThreads).toBe(true)
      expect(ev1.value.seq).toBe(1)
    }

    const ev2 = await iter.next()
    expect(ev2.value.kind).toBe("space.history.clear")
    if (ev2.value.kind === "space.history.clear") {
      expect(ev2.value.spaceId).toBe(20n)
      expect(ev2.value.beforeDate).toBeUndefined()
      expect(ev2.value.deleteReplyThreads).toBe(false)
      expect(ev2.value.seq).toBe(2)
    }

    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 401n,
        body: {
          oneofKind: "message",
          message: {
            payload: {
              oneofKind: "update",
              update: {
                updates: [
                  Update.create({
                    seq: 3,
                    date: 12n,
                    update: {
                      oneofKind: "clearChatHistory",
                      clearChatHistory: {
                        target: {
                          oneofKind: "peerId",
                          peerId: { type: { oneofKind: "user", user: { userId: 1n } } },
                        },
                        deleteReplyThreads: false,
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

    const ev3 = await iter.next()
    expect(ev3.value.kind).toBe("message.history.clear")
    if (ev3.value.kind === "message.history.clear") {
      expect(ev3.value.userId).toBe(1n)
      expect(ev3.value.chatId).toBeUndefined()
      expect(ev3.value.deleteReplyThreads).toBe(false)
      expect(ev3.value.seq).toBe(3)
    }

    await client.close()
  })
})
