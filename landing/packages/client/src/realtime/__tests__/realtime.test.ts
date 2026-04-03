import { describe, expect, it } from "vitest"
import { ServerProtocolMessage } from "@inline-chat/protocol/core"
import { AuthStore, Db, DbObjectKind, RealtimeClient } from "../../index"
import { getChats, getMe, logOut } from "../transactions"
import { MockTransport } from "../transport/mock-transport"

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

describe("realtime connection flow", () => {
  it("sends connection init with token on connect", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const client = new RealtimeClient({
      auth,
      transport,
      url: "ws://example.test",
    })

    await client.startSession({ token: "test-token", userId: 42 })
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
    const client = new RealtimeClient({
      auth,
      transport,
      url: "ws://example.test",
    })

    await client.startSession({ token: "test-token", userId: 1 })
    await connectAndOpen(transport)

    await waitFor(() => client.connectionState === "connected")

    expect(client.connectionState).toBe("connected")

    await client.stop()
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
    })

    await client.startSession({ token: "test-token", userId: 1 })
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

    const user = db.get(db.ref(DbObjectKind.User, 99))
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
    })

    await client.startSession({ token: "test-token", userId: 1 })
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

    const chat = db.get(db.ref(DbObjectKind.Chat, 10))
    const dialog = db.get(db.ref(DbObjectKind.Dialog, 10))
    const user = db.get(db.ref(DbObjectKind.User, 200))
    const message = db.get(db.ref(DbObjectKind.Message, 300))

    expect(chat?.title).toBe("Test chat")
    expect(dialog?.chatId).toBe(10)
    expect(user?.firstName).toBe("Taylor")
    expect(message?.chatId).toBe(10)

    await client.stop()
  })

  it("runs logOut transaction locally", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const client = new RealtimeClient({
      auth,
      transport,
      url: "ws://example.test",
    })

    await client.startSession({ token: "test-token", userId: 1 })
    await connectAndOpen(transport)

    await client.execute(logOut())

    expect(auth.isLoggedIn()).toBe(false)
    expect(client.connectionState).toBe("idle")

    await client.stop()
  })
})
