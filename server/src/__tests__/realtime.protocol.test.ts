import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import {
  newWebsocket,
  wsClose,
  wsClosed,
  wsOpen,
  wsSendClientProtocolMessage,
  wsServerProtocolMessage,
} from "@in/server/realtime/test/utils"
import { Method, PushNotificationProvider } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { sessions } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
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
    const { token, session } = await testUtils.createSessionForUser(user.id, { clientType: "ios" })

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
    return { ws, sessionId: session.id }
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
    const { ws } = await authenticateSocket()
    await wsClosed(ws)
  })

  it("maps rpc method/input mismatch into rpcError instead of crashing", async () => {
    const { ws } = await authenticateSocket()

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
    const { ws } = await authenticateSocket()
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

  it("updates push notification details via RPC", async () => {
    const { ws, sessionId } = await authenticateSocket()
    const publicKey = new Uint8Array(Array.from({ length: 32 }, (_, i) => i + 1))

    wsSendClientProtocolMessage(ws, {
      id: 500n,
      seq: 2,
      body: {
        oneofKind: "rpcCall",
        rpcCall: {
          method: Method.UPDATE_PUSH_NOTIFICATION_DETAILS,
          input: {
            oneofKind: "updatePushNotificationDetails",
            updatePushNotificationDetails: {
              applePushToken: "",
              notificationMethod: {
                provider: PushNotificationProvider.APNS,
                method: {
                  oneofKind: "apns",
                  apns: {
                    deviceToken: "apn-rpc-token",
                  },
                },
              },
              pushContentEncryptionKey: {
                publicKey,
                keyId: "key-v1",
                algorithm: 1,
              },
              pushContentVersion: 1,
            },
          },
        },
      },
    })

    const response = await wsServerProtocolMessage(ws)
    expect(response.body.oneofKind).toBe("rpcResult")
    if (response.body.oneofKind === "rpcResult") {
      expect(response.body.rpcResult.reqMsgId).toBe(500n)
      expect(response.body.rpcResult.result.oneofKind).toBe("updatePushNotificationDetails")
    }

    const session = await db
      .select({
        applePushTokenEncrypted: sessions.applePushTokenEncrypted,
        pushContentKeyPublic: sessions.pushContentKeyPublic,
        pushContentKeyId: sessions.pushContentKeyId,
        pushContentKeyAlgorithm: sessions.pushContentKeyAlgorithm,
        pushContentVersion: sessions.pushContentVersion,
      })
      .from(sessions)
      .where(eq(sessions.id, sessionId))
      .limit(1)
      .then((rows) => rows[0])

    expect(session).toBeDefined()
    expect(session?.applePushTokenEncrypted).toBeTruthy()
    expect(session?.pushContentKeyPublic).toBeTruthy()
    expect(Buffer.from(session?.pushContentKeyPublic ?? []).equals(Buffer.from(publicKey))).toBe(true)
    expect(session?.pushContentKeyId).toBe("key-v1")
    expect(session?.pushContentKeyAlgorithm).toBe("X25519_HKDF_SHA256_AES256_GCM")
    expect(session?.pushContentVersion).toBe(1)

    await wsClosed(ws)
  })

  it("rejects malformed push-content key metadata via RPC", async () => {
    const { ws } = await authenticateSocket()

    wsSendClientProtocolMessage(ws, {
      id: 501n,
      seq: 2,
      body: {
        oneofKind: "rpcCall",
        rpcCall: {
          method: Method.UPDATE_PUSH_NOTIFICATION_DETAILS,
          input: {
            oneofKind: "updatePushNotificationDetails",
            updatePushNotificationDetails: {
              applePushToken: "apn-rpc-token",
              pushContentEncryptionKey: {
                publicKey: new Uint8Array([1, 2, 3]),
                keyId: "key-v1",
                algorithm: 1,
              },
              pushContentVersion: 1,
            },
          },
        },
      },
    })

    const response = await wsServerProtocolMessage(ws)
    expect(response.body.oneofKind).toBe("rpcError")
    if (response.body.oneofKind === "rpcError") {
      expect(response.body.rpcError.reqMsgId).toBe(501n)
    }

    await wsClosed(ws)
  })

  it("clears push-content metadata when update omits key details", async () => {
    const { ws, sessionId } = await authenticateSocket()
    const publicKey = new Uint8Array(Array.from({ length: 32 }, (_, i) => i + 1))

    wsSendClientProtocolMessage(ws, {
      id: 502n,
      seq: 2,
      body: {
        oneofKind: "rpcCall",
        rpcCall: {
          method: Method.UPDATE_PUSH_NOTIFICATION_DETAILS,
          input: {
            oneofKind: "updatePushNotificationDetails",
            updatePushNotificationDetails: {
              applePushToken: "",
              notificationMethod: {
                provider: PushNotificationProvider.APNS,
                method: {
                  oneofKind: "apns",
                  apns: {
                    deviceToken: "apn-rpc-token-a",
                  },
                },
              },
              pushContentEncryptionKey: {
                publicKey,
                keyId: "key-v1",
                algorithm: 1,
              },
              pushContentVersion: 1,
            },
          },
        },
      },
    })

    const firstResponse = await wsServerProtocolMessage(ws)
    expect(firstResponse.body.oneofKind).toBe("rpcResult")
    if (firstResponse.body.oneofKind === "rpcResult") {
      expect(firstResponse.body.rpcResult.reqMsgId).toBe(502n)
    }

    wsSendClientProtocolMessage(ws, {
      id: 503n,
      seq: 3,
      body: {
        oneofKind: "rpcCall",
        rpcCall: {
          method: Method.UPDATE_PUSH_NOTIFICATION_DETAILS,
          input: {
            oneofKind: "updatePushNotificationDetails",
            updatePushNotificationDetails: {
              applePushToken: "",
              notificationMethod: {
                provider: PushNotificationProvider.APNS,
                method: {
                  oneofKind: "apns",
                  apns: {
                    deviceToken: "apn-rpc-token-b",
                  },
                },
              },
            },
          },
        },
      },
    })

    const secondResponse = await wsServerProtocolMessage(ws)
    expect(secondResponse.body.oneofKind).toBe("rpcResult")
    if (secondResponse.body.oneofKind === "rpcResult") {
      expect(secondResponse.body.rpcResult.reqMsgId).toBe(503n)
      expect(secondResponse.body.rpcResult.result.oneofKind).toBe("updatePushNotificationDetails")
    }

    const session = await db
      .select({
        applePushTokenEncrypted: sessions.applePushTokenEncrypted,
        pushContentKeyPublic: sessions.pushContentKeyPublic,
        pushContentKeyId: sessions.pushContentKeyId,
        pushContentKeyAlgorithm: sessions.pushContentKeyAlgorithm,
        pushContentVersion: sessions.pushContentVersion,
      })
      .from(sessions)
      .where(eq(sessions.id, sessionId))
      .limit(1)
      .then((rows) => rows[0])

    expect(session).toBeDefined()
    expect(session?.applePushTokenEncrypted).toBeTruthy()
    expect(session?.pushContentKeyPublic).toBeNull()
    expect(session?.pushContentKeyId).toBeNull()
    expect(session?.pushContentKeyAlgorithm).toBeNull()
    expect(session?.pushContentVersion).toBeNull()

    await wsClosed(ws)
  })
})
