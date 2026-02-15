import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import {
  newWebsocket,
  wsClose,
  wsClosed,
  wsOpen,
  wsSendClientProtocolMessage,
  wsServerProtocolMessage,
} from "@in/server/realtime/test/utils"
import { Method } from "@inline-chat/protocol/core"
import { afterAll, beforeAll, describe, expect, it, mock } from "bun:test"
import Elysia from "elysia"

const handleConnectionOpen = mock().mockResolvedValue(undefined)
const handleConnectionClose = mock().mockResolvedValue(undefined)

// Avoid importing the real PresenceManager in tests (it starts long-lived intervals).
mock.module("@in/server/ws/presence", () => ({
  presenceManager: {
    handleConnectionOpen,
    handleConnectionClose,
  },
}))

setupTestLifecycle()

describe("realtime protocol safety", () => {
  let app: Elysia

  beforeAll(async () => {
    const { realtime } = await import("@in/server/realtime")
    app = new Elysia().use(realtime)
    app.listen(0)
  })

  afterAll(() => {
    app.server?.stop?.()
  })

  const openRealtimeSocket = async () => {
    const ws = newWebsocket(app.server!)
    await wsOpen(ws)
    return ws
  }

  const authenticateSocket = async () => {
    const ws = await openRealtimeSocket()
    const user = await testUtils.createUser("realtime-auth@test.com")
    const { token } = await testUtils.createSessionForUser(user.id)

    wsSendClientProtocolMessage(ws, {
      id: 1n,
      seq: 1,
      body: {
        oneofKind: "connectionInit",
        connectionInit: {
          token,
          layer: 2,
          clientVersion: "1.2.3",
        },
      },
    })

    const openMessage = await wsServerProtocolMessage(ws)
    expect(openMessage.body.oneofKind).toBe("connectionOpen")
    return ws
  }

  it("closes socket for text payloads", async () => {
    const ws = await openRealtimeSocket()
    const closed = wsClose(ws)
    ws.send("invalid-string-message")
    await closed
  })

  it("closes socket for malformed binary payloads", async () => {
    const ws = await openRealtimeSocket()
    const closed = wsClose(ws)
    ws.send(new Uint8Array([1, 2, 3, 4]))
    await closed
  })

  it("returns connectionError when connectionInit token is invalid", async () => {
    const ws = await openRealtimeSocket()

    wsSendClientProtocolMessage(ws, {
      id: 10n,
      seq: 1,
      body: {
        oneofKind: "connectionInit",
        connectionInit: {
          token: "invalid-token",
        },
      },
    })

    const message = await wsServerProtocolMessage(ws)
    expect(message.body.oneofKind).toBe("connectionError")
    await wsClosed(ws)
  })

  it("returns connectionOpen for valid connectionInit token", async () => {
    const ws = await authenticateSocket()
    await wsClosed(ws)
  })

  it("maps rpc method/input mismatch into rpcError instead of crashing", async () => {
    const ws = await authenticateSocket()

    wsSendClientProtocolMessage(ws, {
      id: 99n,
      seq: 2,
      body: {
        oneofKind: "rpcCall",
        rpcCall: {
          method: Method.GET_ME,
          input: {
            oneofKind: "sendMessage",
            sendMessage: {},
          },
        },
      },
    })

    const response = await wsServerProtocolMessage(ws)
    expect(response.body.oneofKind).toBe("rpcError")
    if (response.body.oneofKind === "rpcError") {
      expect(response.body.rpcError.reqMsgId).toBe(99n)
    }
    await wsClosed(ws)
  })

  it("responds to ping with pong and same nonce", async () => {
    const ws = await authenticateSocket()
    const nonce = 12345n

    wsSendClientProtocolMessage(ws, {
      id: 777n,
      seq: 3,
      body: {
        oneofKind: "ping",
        ping: { nonce },
      },
    })

    const response = await wsServerProtocolMessage(ws)
    expect(response.body.oneofKind).toBe("pong")
    if (response.body.oneofKind === "pong") {
      expect(response.body.pong.nonce).toBe(nonce)
    }
    await wsClosed(ws)
  })

  it("keeps server healthy after protocol errors by allowing a fresh socket", async () => {
    const badWs = await openRealtimeSocket()
    const closed = wsClose(badWs)
    badWs.send(new Uint8Array([9, 9, 9]))
    await closed

    const goodWs = await openRealtimeSocket()
    wsSendClientProtocolMessage(goodWs, {
      id: 200n,
      seq: 1,
      body: {
        oneofKind: "ping",
        ping: { nonce: 5n },
      },
    })
    const pong = await wsServerProtocolMessage(goodWs)
    expect(pong.body.oneofKind).toBe("pong")
    await wsClosed(goodWs)
  })
})
