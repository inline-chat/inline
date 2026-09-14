import { afterEach, describe, expect, it } from "vitest"
import { constants, generateKeyPairSync, privateDecrypt, randomBytes } from "node:crypto"
import { EventEmitter } from "node:events"
import { WebSocket, WebSocketServer } from "ws"
import {
  InlineProtocolServerSession,
  acceptObfuscatedClientHeader,
  bytesToHex,
  decodeAbridgedFrame,
  encodeInlineInvoke,
  encodeAbridgedPacket,
  makeRsaPublicKey,
  type EstablishedAuthorizationKey,
  type LoadedServerAuthorizationKey,
  type ObfuscatedServerHeader,
  type ServerAuthorizationKeyRepository,
} from "@inline-chat/protocol/secure"
import {
  AuthBeginResult_Delivery,
  Method,
  RealtimeV3Request,
  RealtimeV3Response,
  RealtimeV3Update,
} from "@inline-chat/protocol/core"
import {
  FrameInbox,
  InlineProtocolV3Connection,
  InlineProtocolV3Error,
  temporaryAuthorizationNeedsRotation,
  type InlineProtocolPublicKey,
} from "./v3-connection.js"
import { InlineSdkClient } from "../sdk/inline-sdk-client.js"
import { ProtocolClient } from "./protocol-client.js"
import { TransportError, type Transport } from "./transport.js"
import { AsyncChannel } from "../utils/async-channel.js"

class MemoryAuthorizationKeys implements ServerAuthorizationKeyRepository {
  readonly values = new Map<string, LoadedServerAuthorizationKey>()

  async create(key: EstablishedAuthorizationKey): Promise<"created"> {
    this.values.set(bytesToHex(key.keyId), {
      key: key.key.slice(),
      keyId: key.keyId.slice(),
      temporary: key.temporary,
      expiresAt: key.expiresAt,
      currentServerSalt: key.serverSalt,
    })
    return "created"
  }

  async load(keyId: Uint8Array): Promise<LoadedServerAuthorizationKey | undefined> {
    const value = this.values.get(bytesToHex(keyId))
    return value && {
      ...value,
      key: value.key.slice(),
      keyId: value.keyId.slice(),
      binding: value.binding && { ...value.binding, permanentAuthKeyId: value.binding.permanentAuthKeyId.slice() },
      authorized: value.authorized && { ...value.authorized },
    }
  }

  async bindTemporary(input: {
    temporaryAuthKeyId: Uint8Array
    permanentAuthKeyId: Uint8Array
    temporarySessionId: bigint
    nonce: bigint
    expiresAt: number
    userId: number
    accountSessionId: number
  }): Promise<"created"> {
    const value = this.values.get(bytesToHex(input.temporaryAuthKeyId))!
    value.binding = {
      permanentAuthKeyId: input.permanentAuthKeyId.slice(),
      temporarySessionId: input.temporarySessionId,
      nonce: input.nonce,
      expiresAt: input.expiresAt,
      userId: input.userId,
      accountSessionId: input.accountSessionId,
    }
    return "created"
  }

  async rotateServerSalt(keyId: Uint8Array, serverSalt: bigint): Promise<boolean> {
    const value = this.values.get(bytesToHex(keyId))
    if (!value) return false
    value.previousServerSalt = value.currentServerSalt
    value.currentServerSalt = serverSalt
    return true
  }

  async revoke(): Promise<boolean> { return true }

  authorize(keyId: Uint8Array): void {
    this.values.get(bytesToHex(keyId))!.authorized = { userId: 7, accountSessionId: 11 }
  }
}

const servers: WebSocketServer[] = []

class OpenWebSocketStub extends EventEmitter {
  binaryType = "arraybuffer"
  readyState = WebSocket.OPEN
  bufferedAmount = 0
  readonly sent: Uint8Array[] = []
  closeCalls = 0

  send(data: unknown): void {
    this.sent.push(Uint8Array.from(data as Uint8Array))
  }

  close(): void {
    this.closeCalls += 1
    this.readyState = WebSocket.CLOSED
    this.emit("close", 1000, Buffer.alloc(0))
  }
}

class FailingSendWebSocketStub extends OpenWebSocketStub {
  override send(): void {
    throw new Error("stub send failed")
  }
}

class BackpressuredWebSocketStub extends OpenWebSocketStub {
  override bufferedAmount = 32 * 1024 * 1024
}

const testAuthorization = () => ({
  key: new Uint8Array(256).fill(0x31),
  keyId: new Uint8Array(8).fill(0x41),
  serverSalt: 7n,
  temporary: true,
  expiresAt: Math.floor(Date.now() / 1_000) + 86_400,
})

describe("temporary authorization rotation boundary", () => {
  const expiresAt = 2_000_086_400
  const boundary = expiresAt * 1_000 - 86_400_000 * 0.8

  it("rotates at exactly 80% of the fixed lifetime", () => {
    expect(temporaryAuthorizationNeedsRotation(expiresAt, boundary - 1)).toBe(false)
    expect(temporaryAuthorizationNeedsRotation(expiresAt, boundary)).toBe(true)
  })

  it("uses authenticated monotonic time rather than a local wall-clock jump", () => {
    expect(temporaryAuthorizationNeedsRotation(expiresAt, boundary - 1)).toBe(false)
    // A local wall clock can jump by hours; the authenticated sample remains before the boundary.
    expect(temporaryAuthorizationNeedsRotation(expiresAt, boundary - 1)).toBe(false)
    expect(temporaryAuthorizationNeedsRotation(expiresAt, boundary + 1)).toBe(true)
  })

  it("permits only the cached-key health probe after the boundary", async () => {
    const socket = new OpenWebSocketStub()
    const connection = await InlineProtocolV3Connection.connect({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
      authorization: {
        ...testAuthorization(),
        expiresAt: Math.floor(Date.now() / 1_000) + 1,
      },
      webSocketFactory: () => socket as unknown as WebSocket,
    })

    await expect(connection.ping()).rejects.toMatchObject({ code: "rotation-due" })
    const probe = connection.probeTemporaryAuthorization()
    expect(socket.sent).toHaveLength(2)
    await connection.close()
    await expect(probe).rejects.toMatchObject({ code: "closed" })
  })
})

afterEach(async () => {
  for (const server of servers.splice(0)) {
    for (const client of server.clients) client.terminate()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  }
})

const testServer = async (options: {
  carrierRpcErrorCode?: number
  applicationRpcErrorCode?: number
} = {}): Promise<{
  url: string
  publicKeys: InlineProtocolPublicKey[]
  pushUpdate: (update: RealtimeV3Update) => void
}> => {
  const pair = generateKeyPairSync("rsa", { modulusLength: 2048, publicExponent: 65537 })
  const jwk = pair.publicKey.export({ format: "jwk" })
  const profile = makeRsaPublicKey(
    Uint8Array.from(Buffer.from(jwk.n!, "base64url")),
    Uint8Array.from(Buffer.from(jwk.e!, "base64url")),
  )
  const keys = new MemoryAuthorizationKeys()
  const server = new WebSocketServer({ port: 0 })
  const active: Array<{
    socket: WebSocket
    session: InlineProtocolServerSession
    carrier: () => ObfuscatedServerHeader | undefined
  }> = []
  servers.push(server)
  server.on("connection", (socket) => {
    let carrier: ObfuscatedServerHeader | undefined
    let queue = Promise.resolve()
    const session = new InlineProtocolServerSession({
      rsaKeys: [{
        ...profile,
        rawDecrypt: (ciphertext) => Uint8Array.from(privateDecrypt({
          key: pair.privateKey,
          padding: constants.RSA_NO_PADDING,
        }, ciphertext)),
      }],
      authorizationKeys: keys,
      replay: {
        claim: async () => ({ kind: "claimed" }),
        complete: async ({ resultBody }) => ({ kind: "completed", resultBody }),
        dropAnswer: async () => "unknown",
        forgetAnswer: async () => {},
      },
      application: {
        dispatch: async ({ payload, authorization }) => {
          const application = RealtimeV3Request.fromBinary(payload)
          if (application.body.oneofKind === "authBegin") {
            return { kind: "result", payload: RealtimeV3Response.toBinary({
              body: { oneofKind: "authBegin", authBegin: {
                challengeId: new Uint8Array(32).fill(7),
                delivery: AuthBeginResult_Delivery.EMAIL,
                expiresAt: 1_700_000_600n,
                retryAfterSeconds: 60,
              } },
            }) }
          }
          if (application.body.oneofKind === "authComplete") {
            keys.authorize(authorization.authKeyId)
            return { kind: "result", payload: RealtimeV3Response.toBinary({
              body: { oneofKind: "authComplete", authComplete: {
                state: { oneofKind: "authorized", authorized: { accountSessionId: 11n } },
              } },
            }) }
          }
          if (application.body.oneofKind === "rpc") {
            if (application.body.rpc.method === Method.DELETE_CHAT && options.applicationRpcErrorCode !== undefined) {
              return { kind: "result", payload: RealtimeV3Response.toBinary({
                body: { oneofKind: "rpcError", rpcError: {
                  reqMsgId: 0n,
                  errorCode: 4,
                  message: "ordinary application error",
                  code: options.applicationRpcErrorCode,
                } },
              }) }
            }
            if (application.body.rpc.method === Method.DELETE_CHAT && options.carrierRpcErrorCode !== undefined) {
              return { kind: "error", code: options.carrierRpcErrorCode, message: "carrier error" }
            }
            const result = application.body.rpc.method === Method.GET_ME
              ? { oneofKind: "getMe" as const, getMe: { user: { id: 7n } } }
              : { oneofKind: undefined }
            return { kind: "result", payload: RealtimeV3Response.toBinary({
              body: { oneofKind: "rpcResult", rpcResult: {
                reqMsgId: 0n,
                result,
              } },
            }) }
          }
          return { kind: "error", code: 400, message: "unexpected request" }
        },
      },
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      nowMilliseconds: () => Date.now(),
      gunzip: () => { throw new Error("not used") },
      carrierProfile: "websocket",
      dc: 1,
    })
    active.push({ socket, session, carrier: () => carrier })
    socket.on("message", (data) => {
      queue = queue.then(async () => {
        const frame = new Uint8Array(data as Buffer)
        if (!carrier) {
          carrier = acceptObfuscatedClientHeader(frame, 1)
          return
        }
        const decoded = decodeAbridgedFrame(carrier.inbound.process(frame))
        if (decoded.kind !== "packet") throw new Error("unexpected quick ACK")
        const responses = await session.receive(decoded.payload)
        for (const response of responses) socket.send(carrier.outbound.process(encodeAbridgedPacket(response)))
      })
    })
  })
  await new Promise<void>((resolve) => server.once("listening", resolve))
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("test server did not bind TCP")
  return {
    url: `ws://127.0.0.1:${address.port}`,
    publicKeys: [{
      modulus: Buffer.from(profile.modulus).toString("base64url"),
      exponent: Buffer.from(profile.exponent).toString("base64url"),
      fingerprint: profile.fingerprint.toString(),
    }],
    pushUpdate: (update) => {
      const target = active.at(-1)
      const carrier = target?.carrier()
      if (!target || !carrier) throw new Error("test connection is not ready")
      const record = target.session.sendApplicationUpdate(RealtimeV3Update.toBinary(update))
      target.socket.send(carrier.outbound.process(encodeAbridgedPacket(record)))
    },
  }
}

const authenticatedTestConnection = async (
  fixture: Awaited<ReturnType<typeof testServer>>,
  options: Partial<Parameters<typeof InlineProtocolV3Connection.connect>[0]> = {},
) => {
  const permanent = await InlineProtocolV3Connection.connect({
    url: fixture.url,
    rsaPublicKeys: fixture.publicKeys,
  })
  const challenge = await permanent.authBegin({ identifier: { oneofKind: "email", email: "v3@example.com" } })
  await permanent.authComplete({ challengeId: challenge.challengeId, code: "123456" })
  const connection = await InlineProtocolV3Connection.connect({
    url: fixture.url,
    rsaPublicKeys: fixture.publicKeys,
    temporary: true,
    ...options,
  })
  await connection.bindTemporary(permanent.authorization)
  return { permanent, connection }
}

describe("InlineProtocolV3Connection", () => {
  it("bounds queued inbound bytes and discards them on terminal failure", async () => {
    const inbox = new FrameInbox(4)
    inbox.push(Uint8Array.of(1, 2, 3))
    expect(() => inbox.push(Uint8Array.of(4, 5))).toThrow("inbound buffer exceeded")
    inbox.fail(new Error("closed"))
    await expect(inbox.next()).rejects.toThrow("closed")
  })

  it("logs in with a permanent key, binds a temporary key, and invokes an RPC", async () => {
    const fixture = await testServer()
    const permanent = await InlineProtocolV3Connection.connect({
      url: fixture.url,
      rsaPublicKeys: fixture.publicKeys,
    })
    const challenge = await permanent.authBegin({
      identifier: { oneofKind: "email", email: "v3@example.com" },
    })
    expect(challenge.challengeId).toEqual(new Uint8Array(32).fill(7))
    const completion = await permanent.authComplete({ challengeId: challenge.challengeId, code: "123456" })
    expect(completion.state.oneofKind).toBe("authorized")

    const temporary = await InlineProtocolV3Connection.connect({
      url: fixture.url,
      rsaPublicKeys: fixture.publicKeys,
      temporary: true,
    })
    await temporary.bindTemporary(permanent.authorization)
    await expect(temporary.callRpc({ method: Method.GET_ME, input: { oneofKind: undefined } })).resolves.toEqual({
      oneofKind: "getMe",
      getMe: { user: { id: 7n } },
    })

    expect(permanent.authorization.temporary).toBe(false)
    expect(temporary.authorization.temporary).toBe(true)
    await temporary.close()
    await permanent.close()
  }, 30_000)

  it("keeps a carrier deadline request-local and the V3 session connected", async () => {
    const fixture = await testServer({ carrierRpcErrorCode: 504 })
    const permanent = await InlineProtocolV3Connection.connect({
      url: fixture.url,
      rsaPublicKeys: fixture.publicKeys,
    })
    const challenge = await permanent.authBegin({ identifier: { oneofKind: "email", email: "v3@example.com" } })
    await permanent.authComplete({ challengeId: challenge.challengeId, code: "123456" })
    const connection = await InlineProtocolV3Connection.connect({
      url: fixture.url,
      rsaPublicKeys: fixture.publicKeys,
      temporary: true,
    })
    await connection.bindTemporary(permanent.authorization)

    await expect(connection.callRpc({ method: Method.DELETE_CHAT, input: { oneofKind: "deleteChat", deleteChat: {} } }))
      .rejects.toMatchObject({ code: "commit-outcome-unknown" })
    await expect(connection.callRpc({ method: Method.GET_ME, input: { oneofKind: undefined } })).resolves.toEqual({
      oneofKind: "getMe",
      getMe: { user: { id: 7n } },
    })

    await connection.close()
    await permanent.close()
  }, 30_000)

  it("keeps a carrier pre-execution rejection request-local and the V3 session connected", async () => {
    const fixture = await testServer({ carrierRpcErrorCode: 503 })
    const permanent = await InlineProtocolV3Connection.connect({
      url: fixture.url,
      rsaPublicKeys: fixture.publicKeys,
    })
    const challenge = await permanent.authBegin({ identifier: { oneofKind: "email", email: "v3@example.com" } })
    await permanent.authComplete({ challengeId: challenge.challengeId, code: "123456" })
    const connection = await InlineProtocolV3Connection.connect({
      url: fixture.url,
      rsaPublicKeys: fixture.publicKeys,
      temporary: true,
    })
    await connection.bindTemporary(permanent.authorization)

    await expect(connection.callRpc({ method: Method.DELETE_CHAT, input: { oneofKind: "deleteChat", deleteChat: {} } }))
      .rejects.toMatchObject({ code: "rejected-before-execution" })
    await expect(connection.callRpc({ method: Method.GET_ME, input: { oneofKind: undefined } })).resolves.toEqual({
      oneofKind: "getMe",
      getMe: { user: { id: 7n } },
    })

    await connection.close()
    await permanent.close()
  }, 30_000)

  it("keeps a protobuf application 504 as an ordinary V3 result", async () => {
    const fixture = await testServer({ applicationRpcErrorCode: 504 })
    const permanent = await InlineProtocolV3Connection.connect({
      url: fixture.url,
      rsaPublicKeys: fixture.publicKeys,
    })
    const challenge = await permanent.authBegin({ identifier: { oneofKind: "email", email: "v3@example.com" } })
    await permanent.authComplete({ challengeId: challenge.challengeId, code: "123456" })
    const connection = await InlineProtocolV3Connection.connect({
      url: fixture.url,
      rsaPublicKeys: fixture.publicKeys,
      temporary: true,
    })
    await connection.bindTemporary(permanent.authorization)

    await expect(connection.invoke({
      body: { oneofKind: "rpc", rpc: {
        method: Method.DELETE_CHAT,
        input: { oneofKind: "deleteChat", deleteChat: {} },
      } },
    })).resolves.toMatchObject({ body: { oneofKind: "rpcError", rpcError: { code: 504 } } })

    await connection.close()
    await permanent.close()
  }, 30_000)

  it("rejects a pinned RSA fingerprint that does not match the key", async () => {
    const fixture = await testServer()
    const connect = InlineProtocolV3Connection.connect({
      url: fixture.url,
      rsaPublicKeys: [{ ...fixture.publicKeys[0]!, fingerprint: "1" }],
    })
    await expect(connect).rejects.toThrow("fingerprint")
  })

  it("closes a socket when connection startup fails", async () => {
    const socket = new FailingSendWebSocketStub()
    await expect(InlineProtocolV3Connection.connect({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
      authorization: testAuthorization(),
      webSocketFactory: () => socket as unknown as WebSocket,
    })).rejects.toThrow("stub send failed")
    expect(socket.closeCalls).toBe(1)
  })

  it("fails closed instead of growing an already backpressured socket", async () => {
    const socket = new BackpressuredWebSocketStub()
    await expect(InlineProtocolV3Connection.connect({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
      authorization: testAuthorization(),
      webSocketFactory: () => socket as unknown as WebSocket,
    })).rejects.toThrow("outbound buffer exceeded")
    expect(socket.closeCalls).toBe(1)
  })

  it("writes multiple RPCs before the first response completes", async () => {
    const socket = new OpenWebSocketStub()
    const connection = await InlineProtocolV3Connection.connect({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
      authorization: testAuthorization(),
      webSocketFactory: () => socket as unknown as WebSocket,
    })
    expect(socket.sent).toHaveLength(1)

    const requests = Array.from({ length: 3 }, () => connection.callRpc({
      method: Method.GET_ME,
      input: { oneofKind: undefined },
    }))
    expect(socket.sent).toHaveLength(4)

    await connection.close()
    expect((await Promise.allSettled(requests)).every(({ status }) => status === "rejected")).toBe(true)
  })

  it("bounds low-level pending requests after outer callers stop awaiting", async () => {
    const socket = new OpenWebSocketStub()
    const connection = await InlineProtocolV3Connection.connect({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
      authorization: testAuthorization(),
      maxPendingRequests: 2,
      maxPendingRequestBytes: 4 * 1024,
      webSocketFactory: () => socket as unknown as WebSocket,
    })
    const request = { method: Method.GET_ME, input: { oneofKind: undefined } } as const
    const outerDeadline = async () => {
      const pending = connection.callRpc(request)
      return await Promise.race([
        pending.then(() => "settled", () => "settled"),
        new Promise<"outer-timeout">((resolve) => setTimeout(() => resolve("outer-timeout"), 1)),
      ])
    }

    await expect(outerDeadline()).resolves.toBe("outer-timeout")
    await expect(outerDeadline()).resolves.toBe("outer-timeout")
    await expect(connection.callRpc(request)).rejects.toMatchObject({ code: "capacity-exceeded" })
    expect(socket.sent).toHaveLength(3)

    await connection.close()
  })

  it("releases low-level pending capacity when an upload RPC is aborted", async () => {
    const socket = new OpenWebSocketStub()
    const connection = await InlineProtocolV3Connection.connect({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
      authorization: testAuthorization(),
      maxPendingRequests: 1,
      maxPendingRequestBytes: 4 * 1024,
      webSocketFactory: () => socket as unknown as WebSocket,
    })
    const request = { method: Method.GET_ME, input: { oneofKind: undefined } } as const
    const controller = new AbortController()
    const aborted = connection.callRpc(request, controller.signal)
    controller.abort()
    await expect(aborted).rejects.toMatchObject({ name: "AbortError" })

    const admitted = connection.callRpc(request)
    await expect(Promise.race([
      admitted.then(() => "settled", () => "settled"),
      new Promise<"pending">((resolve) => setTimeout(() => resolve("pending"), 1)),
    ])).resolves.toBe("pending")
    await connection.close()
    await expect(admitted).rejects.toMatchObject({ code: "closed" })
  })

  it("keeps the low-level cap effective after ProtocolClient deadlines", async () => {
    const socket = new OpenWebSocketStub()
    const connection = await InlineProtocolV3Connection.connect({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
      authorization: testAuthorization(),
      maxPendingRequests: 2,
      maxPendingRequestBytes: 4 * 1024,
      webSocketFactory: () => socket as unknown as WebSocket,
    })
    const transport = {
      events: new AsyncChannel<never>(),
      start: async () => {},
      stop: async () => {},
      stopConnection: async () => {},
      reconnect: async () => {},
      send: async (message: Parameters<Transport["send"]>[0]) => {
        if (message.body.oneofKind !== "rpcCall") return
        try {
          await connection.invoke({ body: { oneofKind: "rpc", rpc: message.body.rpcCall } })
        } catch (error) {
          if (error instanceof InlineProtocolV3Error && error.code === "capacity-exceeded") {
            throw TransportError.capacityExceeded(error.message)
          }
          throw error
        }
      },
    }
    const client = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "test" }),
      maxPendingRpcRequests: 64,
    })
    ;(client as any).state = "open"
    const request = { method: Method.GET_ME, input: { oneofKind: undefined } } as const

    await expect(client.callRpc(request.method, request.input, {
      timeoutMs: 1,
      reconnectPolicy: "replay-safe",
    })).rejects.toMatchObject({ code: "timeout" })
    await expect(client.callRpc(request.method, request.input, {
      timeoutMs: 1,
      reconnectPolicy: "replay-safe",
    })).rejects.toMatchObject({ code: "timeout" })
    await expect(client.callRpc(request.method, request.input, {
      timeoutMs: 1,
      reconnectPolicy: "replay-safe",
    })).rejects.toMatchObject({ code: "capacity-exceeded" })
    expect(socket.sent).toHaveLength(3)

    await connection.close()
  })

  it("releases pending count and body bytes on result, timeout, and close", async () => {
    const request = { identifier: { oneofKind: "email", email: "x".repeat(256) } } as const
    const bodyBytes = encodeInlineInvoke(RealtimeV3Request.toBinary({
      body: { oneofKind: "authBegin", authBegin: request },
    })).byteLength
    const byteLimit = bodyBytes + 1

    const fixture = await testServer()
    const resultSession = await authenticatedTestConnection(fixture, {
      maxPendingRequests: 4,
      maxPendingRequestBytes: byteLimit,
    })
    const firstResult = resultSession.connection.authBegin(request)
    await expect(resultSession.connection.authBegin(request)).rejects.toMatchObject({
      code: "capacity-exceeded",
      message: expect.stringContaining("body-byte"),
    })
    await expect(firstResult).resolves.toMatchObject({ challengeId: new Uint8Array(32).fill(7) })
    await expect(resultSession.connection.authBegin(request)).resolves.toMatchObject({
      challengeId: new Uint8Array(32).fill(7),
    })
    await resultSession.connection.close()
    await resultSession.permanent.close()

    const timeoutSocket = new OpenWebSocketStub()
    const timeoutConnection = await InlineProtocolV3Connection.connect({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
      authorization: testAuthorization(),
      requestTimeoutMs: 10,
      maxPendingRequests: 4,
      maxPendingRequestBytes: byteLimit,
      webSocketFactory: () => timeoutSocket as unknown as WebSocket,
    })
    await expect(timeoutConnection.authBegin(request)).rejects.toMatchObject({ code: "timeout" })
    await expect(timeoutConnection.authBegin(request)).rejects.toMatchObject({ code: "timeout" })
    await timeoutConnection.close()

    const closeSocket = new OpenWebSocketStub()
    const closeConnection = await InlineProtocolV3Connection.connect({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
      authorization: testAuthorization(),
      maxPendingRequests: 4,
      maxPendingRequestBytes: byteLimit,
      webSocketFactory: () => closeSocket as unknown as WebSocket,
    })
    const pendingClose = closeConnection.authBegin(request)
    await closeConnection.close()
    await expect(pendingClose).rejects.toMatchObject({ code: "closed" })
    await expect(closeConnection.authBegin(request)).rejects.toMatchObject({ code: "closed" })
  })

  it("distinguishes a post-dispatch mutation timeout from a query timeout", async () => {
    const socket = new OpenWebSocketStub()
    const connection = await InlineProtocolV3Connection.connect({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
      authorization: testAuthorization(),
      requestTimeoutMs: 10,
      webSocketFactory: () => socket as unknown as WebSocket,
    })

    await expect(connection.callRpc({
      method: Method.DELETE_CHAT,
      input: { oneofKind: "deleteChat", deleteChat: {} },
    })).rejects.toMatchObject({ code: "commit-outcome-unknown" })
    await expect(connection.callRpc({
      method: Method.GET_ME,
      input: { oneofKind: undefined },
    })).rejects.toMatchObject({ code: "timeout" })

    await connection.close()
  })

  it("distinguishes a post-dispatch mutation close from a query close", async () => {
    const mutationSocket = new OpenWebSocketStub()
    const mutationConnection = await InlineProtocolV3Connection.connect({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
      authorization: testAuthorization(),
      webSocketFactory: () => mutationSocket as unknown as WebSocket,
    })
    const mutation = mutationConnection.callRpc({
      method: Method.DELETE_CHAT,
      input: { oneofKind: "deleteChat", deleteChat: {} },
    })
    await mutationConnection.close()
    await expect(mutation).rejects.toMatchObject({ code: "commit-outcome-unknown" })

    const querySocket = new OpenWebSocketStub()
    const queryConnection = await InlineProtocolV3Connection.connect({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
      authorization: testAuthorization(),
      webSocketFactory: () => querySocket as unknown as WebSocket,
    })
    const query = queryConnection.callRpc({
      method: Method.GET_SPACE,
      input: { oneofKind: "getSpace", getSpace: { spaceId: 7n } },
    })
    await queryConnection.close()
    await expect(query).rejects.toMatchObject({ code: "closed" })
  })

  it("maps the authenticated session-revoked close code to a terminal authorization failure", async () => {
    const socket = new OpenWebSocketStub()
    let closed: Error | undefined
    const connection = await InlineProtocolV3Connection.connect({
      url: "ws://inline.test/realtime/v3",
      rsaPublicKeys: [],
      authorization: testAuthorization(),
      webSocketFactory: () => socket as unknown as WebSocket,
      onClose: (error) => { closed = error },
    })

    socket.readyState = WebSocket.CLOSED
    socket.emit("close", 4401, Buffer.from("session_revoked"))

    await expect.poll(() => closed).toBeInstanceOf(InlineProtocolV3Error)
    expect(closed).toMatchObject({ code: "unauthorized" })
    await connection.close()
  })

  it("delivers an unsolicited update while no RPC is in flight", async () => {
    const fixture = await testServer()
    const permanent = await InlineProtocolV3Connection.connect({
      url: fixture.url,
      rsaPublicKeys: fixture.publicKeys,
    })
    const challenge = await permanent.authBegin({
      identifier: { oneofKind: "email", email: "v3@example.com" },
    })
    await permanent.authComplete({ challengeId: challenge.challengeId, code: "123456" })

    let resolveUpdate: ((update: RealtimeV3Update) => void) | undefined
    const received = new Promise<RealtimeV3Update>((resolve) => { resolveUpdate = resolve })
    const temporary = await InlineProtocolV3Connection.connect({
      url: fixture.url,
      rsaPublicKeys: fixture.publicKeys,
      temporary: true,
      onUpdate: (update) => resolveUpdate?.(update),
    })
    await temporary.bindTemporary(permanent.authorization)

    fixture.pushUpdate({ message: { payload: { oneofKind: undefined } } })
    await expect(Promise.race([
      received,
      new Promise((_, reject) => setTimeout(() => reject(new Error("update timed out")), 2_000)),
    ])).resolves.toEqual({ message: { payload: { oneofKind: undefined } } })

    await temporary.close()
    await permanent.close()
  }, 30_000)

  it("uses V3 as the high-level SDK session owner", async () => {
    const fixture = await testServer()
    const permanent = await InlineProtocolV3Connection.connect({
      url: fixture.url,
      rsaPublicKeys: fixture.publicKeys,
    })
    const challenge = await permanent.authBegin({
      identifier: { oneofKind: "email", email: "v3@example.com" },
    })
    await permanent.authComplete({ challengeId: challenge.challengeId, code: "123456" })

    let storedTemporary = false
    const client = new InlineSdkClient({
      baseUrl: "http://127.0.0.1",
      inlineProtocol: {
        credentials: { permanent: permanent.authorization },
        rsaPublicKeys: fixture.publicKeys,
        realtimeUrl: fixture.url,
        onCredentials: (credentials) => { storedTemporary = credentials.temporary !== undefined },
      },
    })
    await client.connect()
    await expect(client.getMe()).resolves.toEqual({ userId: 7n })
    expect(storedTemporary).toBe(true)

    await client.close()
    await permanent.close()
  }, 30_000)
})
