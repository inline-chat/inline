import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import {
  newWebsocket,
  wsClose,
  wsClosed,
  wsOpen,
  wsSendClientProtocolMessage,
  wsServerProtocolMessage,
} from "@in/server/realtime/test/utils"
import { sendMessageToRealtimeSession } from "@in/server/realtime/message"
import {
  ConnectionError_Reason,
  MessageEntity_Type,
  Method,
  PushNotificationProvider,
  RpcError_Code,
  UsernameAvailability,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { sessions, users } from "@in/server/db/schema"
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
  let app: any

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
    return { ws, userId: user.id, sessionId: session.id, token }
  }

  const authenticateExistingUserSocket = async (
    userId: number,
    clientType: "ios" | "macos" | "web" | "api" | "android" | "cli" = "macos",
  ) => {
    const ws = await openRealtimeSocket()
    const { token, session } = await testUtils.createSessionForUser(userId, { clientType })

    wsSendClientProtocolMessage(ws, {
      id: BigInt(10_000 + session.id),
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

  const authenticateExistingSessionSocket = async (token: string) => {
    const ws = await openRealtimeSocket()

    wsSendClientProtocolMessage(ws, {
      id: 9_999n,
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

  const sendRealtimeText = async ({
    ws,
    userId,
    text,
    requestId,
    parseMarkdown,
  }: {
    ws: WebSocket
    userId: number
    text: string
    requestId: bigint
    parseMarkdown?: boolean
  }) => {
    wsSendClientProtocolMessage(ws, {
      id: requestId,
      seq: 2,
      body: {
        oneofKind: "rpcCall",
        rpcCall: {
          method: Method.SEND_MESSAGE,
          input: {
            oneofKind: "sendMessage",
            sendMessage: {
              peerId: {
                type: {
                  oneofKind: "user",
                  user: { userId: BigInt(userId) },
                },
              },
              message: text,
              randomId: requestId,
              ...(parseMarkdown !== undefined ? { parseMarkdown } : {}),
            },
          },
        },
      },
    })

    const response = await wsServerProtocolMessage(ws)
    expect(response.body.oneofKind).toBe("rpcResult")
    if (response.body.oneofKind !== "rpcResult") return undefined
    expect(response.body.rpcResult.result.oneofKind).toBe("sendMessage")
    if (response.body.rpcResult.result.oneofKind !== "sendMessage") return undefined

    const update = response.body.rpcResult.result.sendMessage.updates.find(
      (candidate) => candidate.update.oneofKind === "newMessage",
    )
    return update?.update.oneofKind === "newMessage"
      ? update.update.newMessage.message
      : undefined
  }

  it("defaults omitted Markdown parsing for bot Realtime RPC and preserves explicit false", async () => {
    const bot = await testUtils.createUser("realtime-markdown-bot@test.com")
    await db.update(users).set({ bot: true }).where(eq(users.id, bot.id))
    const recipient = await testUtils.createUser("realtime-markdown-recipient@test.com")
    await testUtils.createPrivateChat(bot, recipient)
    const { ws } = await authenticateExistingUserSocket(bot.id, "api")

    const parsed = await sendRealtimeText({
      ws,
      userId: recipient.id,
      text: "hello **world**",
      requestId: 81_001n,
    })
    expect(parsed?.message).toBe("hello world")
    expect(parsed?.entities?.entities[0]?.type).toBe(MessageEntity_Type.BOLD)

    const literal = await sendRealtimeText({
      ws,
      userId: recipient.id,
      text: "literal **world**",
      requestId: 81_002n,
      parseMarkdown: false,
    })
    expect(literal?.message).toBe("literal **world**")
    expect(literal?.entities).toBeUndefined()

    await wsClosed(ws)
  })

  it("preserves omitted Markdown parsing for human Realtime RPC", async () => {
    const sender = await testUtils.createUser("realtime-markdown-human@test.com")
    const recipient = await testUtils.createUser("realtime-markdown-human-recipient@test.com")
    await testUtils.createPrivateChat(sender, recipient)
    const { ws } = await authenticateExistingUserSocket(sender.id, "api")

    const literal = await sendRealtimeText({
      ws,
      userId: recipient.id,
      text: "human **literal**",
      requestId: 81_003n,
    })
    expect(literal?.message).toBe("human **literal**")
    expect(literal?.entities).toBeUndefined()

    await wsClosed(ws)
  })

  it("routes session-scoped messages to every matching socket and no other app session", async () => {
    const target = await authenticateSocket()
    const reconnectOverlap = await authenticateExistingSessionSocket(target.token)
    const otherSession = await authenticateExistingUserSocket(target.userId)
    let otherSessionMessageCount = 0
    otherSession.ws.addEventListener("message", () => {
      otherSessionMessageCount += 1
    })

    const firstDelivery = wsServerProtocolMessage(target.ws)
    const overlapDelivery = wsServerProtocolMessage(reconnectOverlap)
    await sendMessageToRealtimeSession(target.userId, target.sessionId, {
      oneofKind: "update",
      update: { updates: [] },
    })

    const [firstMessage, overlapMessage] = await Promise.all([firstDelivery, overlapDelivery])
    expect(firstMessage.body.oneofKind).toBe("message")
    expect(overlapMessage.body.oneofKind).toBe("message")
    expect(firstMessage.id).toBe(overlapMessage.id)
    await Bun.sleep(25)
    expect(otherSessionMessageCount).toBe(0)

    await wsClosed(otherSession.ws)
    await wsClosed(reconnectOverlap)
    await wsClosed(target.ws)
  })

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
    if (message.body.oneofKind === "connectionError") {
      expect(message.body.connectionError.reason).toBe(ConnectionError_Reason.INVALID_AUTH)
    }
    await wsClosed(ws)
  })

  it("returns sessionRevoked connectionError when connectionInit token is revoked", async () => {
    const ws = await openRealtimeSocket()
    const user = await testUtils.createUser("realtime-revoked-auth@test.com")
    const { token, session } = await testUtils.createSessionForUser(user.id, { clientType: "ios" })

    await db.update(sessions).set({ revoked: new Date() }).where(eq(sessions.id, session.id))

    wsSendClientProtocolMessage(ws, {
      id: 11n,
      seq: 1,
      body: {
        oneofKind: "connectionInit",
        connectionInit: {
          token,
        },
      },
    })

    const message = await wsServerProtocolMessage(ws)
    expect(message.body.oneofKind).toBe("connectionError")
    if (message.body.oneofKind === "connectionError") {
      expect(message.body.connectionError.reason).toBe(ConnectionError_Reason.SESSION_REVOKED)
    }
    await wsClosed(ws)
  })

  it("returns unauthorized connectionError when connectionInit token belongs to a deleted user", async () => {
    const ws = await openRealtimeSocket()
    const user = await testUtils.createUser("realtime-deleted-auth@test.com")
    const { token } = await testUtils.createSessionForUser(user.id, { clientType: "ios" })

    await db.update(users).set({ deleted: true }).where(eq(users.id, user.id))

    wsSendClientProtocolMessage(ws, {
      id: 12n,
      seq: 1,
      body: {
        oneofKind: "connectionInit",
        connectionInit: {
          token,
        },
      },
    })

    const message = await wsServerProtocolMessage(ws)
    expect(message.body.oneofKind).toBe("connectionError")
    if (message.body.oneofKind === "connectionError") {
      expect(message.body.connectionError.reason).toBe(ConnectionError_Reason.UNAUTHORIZED)
    }
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

  it("returns explicit rpcError for unsupported rpc methods", async () => {
    const { ws } = await authenticateSocket()

    wsSendClientProtocolMessage(ws, {
      id: 100n,
      seq: 2,
      body: {
        oneofKind: "rpcCall",
        rpcCall: {
          method: 999 as Method,
          input: { oneofKind: undefined },
        },
      },
    })

    const response = await wsServerProtocolMessage(ws)
    expect(response.body.oneofKind).toBe("rpcError")
    if (response.body.oneofKind === "rpcError") {
      expect(response.body.rpcError.reqMsgId).toBe(100n)
      expect(response.body.rpcError.errorCode).toBe(RpcError_Code.BAD_REQUEST)
      expect(response.body.rpcError.code).toBe(400)
      expect(response.body.rpcError.message).toContain("Unsupported RPC method: 999")
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
        pushNotificationProvider: sessions.pushNotificationProvider,
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
    expect(session?.pushNotificationProvider).toBe("apns")
    expect(session?.pushContentKeyPublic).toBeTruthy()
    expect(Buffer.from(session?.pushContentKeyPublic ?? []).equals(Buffer.from(publicKey))).toBe(true)
    expect(session?.pushContentKeyId).toBe("key-v1")
    expect(session?.pushContentKeyAlgorithm).toBe("X25519_HKDF_SHA256_AES256_GCM")
    expect(session?.pushContentVersion).toBe(1)

    await wsClosed(ws)
  })

  it("updates Expo Android push notification details via RPC", async () => {
    const { ws, sessionId } = await authenticateSocket()

    wsSendClientProtocolMessage(ws, {
      id: 504n,
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
                provider: PushNotificationProvider.EXPO_ANDROID,
                method: {
                  oneofKind: "expoAndroid",
                  expoAndroid: {
                    expoPushToken: "ExponentPushToken[rpc-android-token]",
                  },
                },
              },
            },
          },
        },
      },
    })

    const response = await wsServerProtocolMessage(ws)
    expect(response.body.oneofKind).toBe("rpcResult")
    if (response.body.oneofKind === "rpcResult") {
      expect(response.body.rpcResult.reqMsgId).toBe(504n)
      expect(response.body.rpcResult.result.oneofKind).toBe("updatePushNotificationDetails")
    }

    const session = await db
      .select({
        applePushTokenEncrypted: sessions.applePushTokenEncrypted,
        pushNotificationProvider: sessions.pushNotificationProvider,
        pushContentKeyPublic: sessions.pushContentKeyPublic,
        pushContentVersion: sessions.pushContentVersion,
      })
      .from(sessions)
      .where(eq(sessions.id, sessionId))
      .limit(1)
      .then((rows) => rows[0])

    expect(session).toBeDefined()
    expect(session?.applePushTokenEncrypted).toBeTruthy()
    expect(session?.pushNotificationProvider).toBe("expo_android")
    expect(session?.pushContentKeyPublic).toBeNull()
    expect(session?.pushContentVersion).toBeNull()

    await wsClosed(ws)
  })

  it("infers Expo Android push provider for legacy Android push-token RPC", async () => {
    const user = await testUtils.createUser("realtime-android-legacy-push@test.com")
    const { ws, sessionId } = await authenticateExistingUserSocket(user.id, "android")

    wsSendClientProtocolMessage(ws, {
      id: 506n,
      seq: 2,
      body: {
        oneofKind: "rpcCall",
        rpcCall: {
          method: Method.UPDATE_PUSH_NOTIFICATION_DETAILS,
          input: {
            oneofKind: "updatePushNotificationDetails",
            updatePushNotificationDetails: {
              applePushToken: "ExponentPushToken[legacy-rpc-android-token]",
            },
          },
        },
      },
    })

    const response = await wsServerProtocolMessage(ws)
    expect(response.body.oneofKind).toBe("rpcResult")
    if (response.body.oneofKind === "rpcResult") {
      expect(response.body.rpcResult.reqMsgId).toBe(506n)
      expect(response.body.rpcResult.result.oneofKind).toBe("updatePushNotificationDetails")
    }

    const session = await db
      .select({
        applePushTokenEncrypted: sessions.applePushTokenEncrypted,
        pushNotificationProvider: sessions.pushNotificationProvider,
      })
      .from(sessions)
      .where(eq(sessions.id, sessionId))
      .limit(1)
      .then((rows) => rows[0])

    expect(session).toBeDefined()
    expect(session?.applePushTokenEncrypted).toBeTruthy()
    expect(session?.pushNotificationProvider).toBe("expo_android")

    await wsClosed(ws)
  })

  it("revokes another session via RPC", async () => {
    const { ws, userId } = await authenticateSocket()
    const otherSession = await testUtils.createSessionForUser(userId, { clientType: "macos" })

    wsSendClientProtocolMessage(ws, {
      id: 600n,
      seq: 2,
      body: {
        oneofKind: "rpcCall",
        rpcCall: {
          method: Method.REVOKE_SESSION,
          input: {
            oneofKind: "revokeSession",
            revokeSession: {
              sessionId: BigInt(otherSession.session.id),
            },
          },
        },
      },
    })

    const response = await wsServerProtocolMessage(ws)
    expect(response.body.oneofKind).toBe("rpcResult")
    if (response.body.oneofKind === "rpcResult") {
      expect(response.body.rpcResult.reqMsgId).toBe(600n)
      expect(response.body.rpcResult.result.oneofKind).toBe("revokeSession")
      if (response.body.rpcResult.result.oneofKind === "revokeSession") {
        expect(response.body.rpcResult.result.revokeSession.revoked).toBe(true)
        expect(response.body.rpcResult.result.revokeSession.alreadyRevoked).toBe(false)
      }
    }

    const revoked = await db
      .select({ revoked: sessions.revoked, active: sessions.active })
      .from(sessions)
      .where(eq(sessions.id, otherSession.session.id))
      .limit(1)
      .then((rows) => rows[0])
    expect(revoked?.revoked).not.toBeNull()
    expect(revoked?.active).toBe(false)

    await wsClosed(ws)
  })

  it("lists active account sessions via RPC", async () => {
    const { ws, userId, sessionId } = await authenticateSocket()
    const otherSession = await testUtils.createSessionForUser(userId, {
      clientType: "macos",
      deviceName: "MacBook Pro",
      clientVersion: "1.2.3",
      osVersion: "macOS 15.2",
    })

    wsSendClientProtocolMessage(ws, {
      id: 601n,
      seq: 2,
      body: {
        oneofKind: "rpcCall",
        rpcCall: {
          method: Method.GET_SESSIONS,
          input: {
            oneofKind: "getSessions",
            getSessions: {},
          },
        },
      },
    })

    const response = await wsServerProtocolMessage(ws)
    expect(response.body.oneofKind).toBe("rpcResult")
    if (response.body.oneofKind === "rpcResult") {
      expect(response.body.rpcResult.reqMsgId).toBe(601n)
      expect(response.body.rpcResult.result.oneofKind).toBe("getSessions")
      if (response.body.rpcResult.result.oneofKind === "getSessions") {
        const sessionsResult = response.body.rpcResult.result.getSessions.sessions
        expect(sessionsResult.some((session) => session.id === BigInt(sessionId) && session.current)).toBe(true)
        expect(
          sessionsResult.some(
            (session) =>
              session.id === BigInt(otherSession.session.id) &&
              session.clientType === "macos" &&
              session.deviceName === "MacBook Pro" &&
              session.clientVersion === "1.2.3" &&
              !session.current,
          ),
        ).toBe(true)
      }
    }

    await wsClosed(ws)
  })

  it("checks username availability via RPC", async () => {
    const { ws, userId } = await authenticateSocket()
    const existing = await testUtils.createUser("username-taken@example.com")
    await db.update(users).set({ username: "mine" }).where(eq(users.id, userId))
    await db.update(users).set({ username: "taken" }).where(eq(users.id, existing.id))

    const check = async (id: bigint, username: string) => {
      wsSendClientProtocolMessage(ws, {
        id,
        seq: Number(id),
        body: {
          oneofKind: "rpcCall",
          rpcCall: {
            method: Method.CHECK_USERNAME,
            input: {
              oneofKind: "checkUsername",
              checkUsername: { username },
            },
          },
        },
      })

      const response = await wsServerProtocolMessage(ws)
      expect(response.body.oneofKind).toBe("rpcResult")
      if (response.body.oneofKind !== "rpcResult") {
        throw new Error("Expected rpcResult")
      }
      expect(response.body.rpcResult.result.oneofKind).toBe("checkUsername")
      if (response.body.rpcResult.result.oneofKind !== "checkUsername") {
        throw new Error("Expected checkUsername result")
      }
      return response.body.rpcResult.result.checkUsername.availability
    }

    expect(await check(610n, "freshhandle")).toBe(UsernameAvailability.USERNAME_AVAILABLE)
    expect(await check(611n, "mine")).toBe(UsernameAvailability.USERNAME_CURRENT)
    expect(await check(612n, "taken")).toBe(UsernameAvailability.USERNAME_TAKEN)
    expect(await check(613n, "inline")).toBe(UsernameAvailability.USERNAME_RESERVED)
    expect(await check(614n, "a")).toBe(UsernameAvailability.USERNAME_INVALID)

    await wsClosed(ws)
  })

  it("changes and clears username via RPC", async () => {
    const { ws, userId } = await authenticateSocket()

    wsSendClientProtocolMessage(ws, {
      id: 620n,
      seq: 2,
      body: {
        oneofKind: "rpcCall",
        rpcCall: {
          method: Method.CHANGE_USERNAME,
          input: {
            oneofKind: "changeUsername",
            changeUsername: { username: "@newhandle" },
          },
        },
      },
    })

    const setResponse = await wsServerProtocolMessage(ws)
    expect(setResponse.body.oneofKind).toBe("rpcResult")
    if (setResponse.body.oneofKind === "rpcResult") {
      expect(setResponse.body.rpcResult.result.oneofKind).toBe("changeUsername")
      if (setResponse.body.rpcResult.result.oneofKind === "changeUsername") {
        const user = setResponse.body.rpcResult.result.changeUsername.user
        expect(user).toBeDefined()
        if (!user) {
          throw new Error("Expected changeUsername user")
        }
        expect(user.username).toBe("newhandle")
      }
    }

    const [storedUser] = await db.select().from(users).where(eq(users.id, userId))
    expect(storedUser?.username).toBe("newhandle")

    wsSendClientProtocolMessage(ws, {
      id: 621n,
      seq: 3,
      body: {
        oneofKind: "rpcCall",
        rpcCall: {
          method: Method.CHANGE_USERNAME,
          input: {
            oneofKind: "changeUsername",
            changeUsername: { username: "" },
          },
        },
      },
    })

    const clearResponse = await wsServerProtocolMessage(ws)
    expect(clearResponse.body.oneofKind).toBe("rpcResult")
    if (clearResponse.body.oneofKind === "rpcResult") {
      expect(clearResponse.body.rpcResult.result.oneofKind).toBe("changeUsername")
      if (clearResponse.body.rpcResult.result.oneofKind === "changeUsername") {
        const user = clearResponse.body.rpcResult.result.changeUsername.user
        expect(user).toBeDefined()
        if (!user) {
          throw new Error("Expected changeUsername user")
        }
        expect(user.username).toBeUndefined()
      }
    }

    const [clearedUser] = await db.select().from(users).where(eq(users.id, userId))
    expect(clearedUser?.username).toBeNull()

    await wsClosed(ws)
  })

  it("updates profile name and bio via RPC", async () => {
    const { ws, userId } = await authenticateSocket()
    await db.update(users).set({ firstName: "Old", lastName: "Name", bio: "Old bio" }).where(eq(users.id, userId))
    const other = await authenticateExistingUserSocket(userId)
    const pushedUpdate = wsServerProtocolMessage(other.ws)

    wsSendClientProtocolMessage(ws, {
      id: 630n,
      seq: 2,
      body: {
        oneofKind: "rpcCall",
        rpcCall: {
          method: Method.UPDATE_PROFILE,
          input: {
            oneofKind: "updateProfile",
            updateProfile: {
              firstName: " M ",
              lastName: " ",
              bio: " Building Inline ",
            },
          },
        },
      },
    })

    const response = await wsServerProtocolMessage(ws)
    expect(response.body.oneofKind).toBe("rpcResult")
    if (response.body.oneofKind === "rpcResult") {
      expect(response.body.rpcResult.result.oneofKind).toBe("updateProfile")
      if (response.body.rpcResult.result.oneofKind === "updateProfile") {
        const user = response.body.rpcResult.result.updateProfile.user
        expect(user).toBeDefined()
        if (!user) {
          throw new Error("Expected updateProfile user")
        }
        expect(user.firstName).toBe("M")
        expect(user.lastName).toBeUndefined()
        expect(user.bio).toBe("Building Inline")
        expect(response.body.rpcResult.result.updateProfile.updates).toHaveLength(1)
        const update = response.body.rpcResult.result.updateProfile.updates[0]
        expect(update?.update.oneofKind).toBe("updatedUser")
        if (update?.update.oneofKind === "updatedUser") {
          const updatedUser = update.update.updatedUser.user
          expect(updatedUser).toBeDefined()
          if (!updatedUser) throw new Error("Expected updated user")
          expect(updatedUser.firstName).toBe("M")
          expect(updatedUser.bio).toBe("Building Inline")
        }
      }
    }

    const pushed = await pushedUpdate
    expect(pushed.body.oneofKind).toBe("message")
    if (pushed.body.oneofKind === "message") {
      expect(pushed.body.message.payload.oneofKind).toBe("update")
      if (pushed.body.message.payload.oneofKind !== "update") {
        throw new Error("Expected update payload")
      }
      expect(pushed.body.message.payload.update.updates).toHaveLength(1)
      const update = pushed.body.message.payload.update.updates[0]
      expect(update?.update.oneofKind).toBe("updatedUser")
      if (update?.update.oneofKind === "updatedUser") {
        const updatedUser = update.update.updatedUser.user
        expect(updatedUser).toBeDefined()
        if (!updatedUser) throw new Error("Expected pushed user")
        expect(updatedUser.id).toBe(BigInt(userId))
        expect(updatedUser.firstName).toBe("M")
      }
    }

    const [storedUser] = await db.select().from(users).where(eq(users.id, userId))
    expect(storedUser?.firstName).toBe("M")
    expect(storedUser?.lastName).toBeNull()
    expect(storedUser?.bio).toBe("Building Inline")

    await wsClosed(other.ws)
    await wsClosed(ws)
  })

  it("returns profile-specific rpc errors for invalid writes", async () => {
    const { ws } = await authenticateSocket()

    wsSendClientProtocolMessage(ws, {
      id: 640n,
      seq: 2,
      body: {
        oneofKind: "rpcCall",
        rpcCall: {
          method: Method.UPDATE_PROFILE,
          input: {
            oneofKind: "updateProfile",
            updateProfile: { firstName: " " },
          },
        },
      },
    })

    const response = await wsServerProtocolMessage(ws)
    expect(response.body.oneofKind).toBe("rpcError")
    if (response.body.oneofKind === "rpcError") {
      expect(response.body.rpcError.errorCode).toBe(RpcError_Code.FIRST_NAME_INVALID)
      expect(response.body.rpcError.code).toBe(400)
    }

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

  it("rejects push-content key metadata for Expo Android push registration", async () => {
    const { ws } = await authenticateSocket()

    wsSendClientProtocolMessage(ws, {
      id: 505n,
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
                provider: PushNotificationProvider.EXPO_ANDROID,
                method: {
                  oneofKind: "expoAndroid",
                  expoAndroid: {
                    expoPushToken: "ExponentPushToken[rpc-android-token]",
                  },
                },
              },
              pushContentEncryptionKey: {
                publicKey: new Uint8Array(Array.from({ length: 32 }, (_, i) => i + 1)),
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
      expect(response.body.rpcError.reqMsgId).toBe(505n)
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
