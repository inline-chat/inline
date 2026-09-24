import { describe, expect, spyOn, test } from "bun:test"
import { constants, generateKeyPairSync, privateDecrypt, randomBytes } from "node:crypto"
import type { Server, ServerWebSocket } from "bun"
import {
  InlineHandshakeClient,
  MessageIdGenerator,
  ServiceConstructor,
  authKeyId,
  bytesToHex,
  createObfuscatedClientHeader,
  decodeAbridgedFrame,
  decodeAbridgedPacket,
  decodeInlineApplicationObject,
  decodeMsgsAck,
  decodeRpcResult,
  decryptRecord,
  decryptRecordWithMetadata,
  encodeAbridgedPacket,
  encodeInlineInvoke,
  encodePing,
  encryptRecord,
  isValidObfuscatedHeader,
  readInt64LE,
  serviceConstructor,
} from "@inline-chat/protocol/secure"
import {
  RealtimeV3Request,
  RealtimeV3Response,
  RealtimeV3Update,
  ServerProtocolMessage,
} from "@inline-chat/protocol/core"
import {
  decodeUnencryptedRecord,
  encodeUnencryptedRecord,
  makeRsaPublicKey,
  type EstablishedAuthorizationKey,
  type LoadedServerAuthorizationKey,
  type ServerApplicationAuthorization,
  type ServerAuthorizationKeyRepository,
  type ServerReplayRepository,
} from "@inline-chat/protocol/server"
import {
  makeInlineProtocolRealtimeTransport,
  realtimeV3Log,
  type InlineProtocolRuntime,
  type InlineProtocolWebSocketData,
} from "./realtimeV3Host"
import { InlineProtocolClock } from "@in/server/modules/inlineProtocol/clockHealth"
import { sessionAuthority } from "@in/server/modules/auth/sessionAuthority"
import { connectionManager } from "@in/server/ws/connections"
import { makeCombinedWebsocket, type CoreWebSocketData } from "./combinedWebsocket"
import { makeCoreRealtimeTransport } from "./realtimeHost"
import { Context, Effect } from "effect"
import { ErrorReporter } from "../errors/errorReporter"
import { RealtimeSessions } from "../../realtime/host.effect"
import { ClientMessage } from "@inline-chat/protocol/core"
import { createConnection } from "node:net"

class MemoryKeys implements ServerAuthorizationKeyRepository {
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
  async load(authKeyId: Uint8Array): Promise<LoadedServerAuthorizationKey | undefined> {
    return this.values.get(bytesToHex(authKeyId))
  }
  async bindTemporary(): Promise<"created"> { return "created" }
  async rotateServerSalt(): Promise<boolean> { return false }
  async revoke(): Promise<boolean> { return false }
}

const fixture = (
  operations: unknown = {},
  clock: Pick<InlineProtocolClock, "assertHealthy" | "nowMilliseconds"> = new InlineProtocolClock(),
): InlineProtocolRuntime & {
  clientKey: ReturnType<typeof makeRsaPublicKey>
  authorizationKeys: MemoryKeys
} => {
  const pair = generateKeyPairSync("rsa", { modulusLength: 2048, publicExponent: 65537 })
  const jwk = pair.publicKey.export({ format: "jwk" })
  const clientKey = makeRsaPublicKey(
    Uint8Array.from(Buffer.from(jwk.n!, "base64url")),
    Uint8Array.from(Buffer.from(jwk.e!, "base64url")),
  )
  return {
    clientKey,
    rsaKeys: [{
      ...clientKey,
      rawDecrypt: (ciphertext) => Uint8Array.from(privateDecrypt({
        key: pair.privateKey,
        padding: constants.RSA_NO_PADDING,
      }, ciphertext)),
    }],
    authorizationKeys: new MemoryKeys(),
    replay: {
      claim: async () => ({ kind: "claimed" }),
      complete: async () => ({ kind: "completed" }),
      dropAnswer: async () => "unknown",
      forgetAnswer: async () => {},
    } satisfies ServerReplayRepository,
    operations: operations as never,
    clock,
    close: () => {},
  }
}

const paddingFor = (bodyLength: number): Uint8Array =>
  randomBytes(12 + ((16 - ((32 + bodyLength + 12) % 16)) % 16))

const connectSocket = (url: string) => {
  const socket = new WebSocket(url)
  socket.binaryType = "arraybuffer"
  const messages: Uint8Array[] = []
  let pending: ((bytes: Uint8Array) => void) | undefined
  socket.addEventListener("message", (event) => {
    const bytes = new Uint8Array(event.data as ArrayBuffer)
    if (pending) { const resolve = pending; pending = undefined; resolve(bytes) }
    else messages.push(bytes)
  })
  const opened = new Promise<void>((resolve, reject) => {
    socket.addEventListener("open", () => resolve(), { once: true })
    socket.addEventListener("error", () => reject(new Error("Local socket failed")), { once: true })
  })
  return { socket, opened, next: () => {
    const message = messages.shift()
    return message ? Promise.resolve(message) : new Promise<Uint8Array>((resolve) => { pending = resolve })
  } }
}

const combinedListener = () => {
  const runtime = fixture()
  const v3 = makeInlineProtocolRealtimeTransport(runtime)
  const context = Context.make(ErrorReporter, { report: () => Effect.void }).pipe(Context.add(RealtimeSessions, {
    open: (peer) => Effect.succeed({
      connectionId: peer.id, close: Effect.void,
      handle: (message) => Effect.sync(() => { peer.sendBinary(ClientMessage.toBinary(message), true) }),
    }),
  }))
  const v2 = makeCoreRealtimeTransport(context)
  const handler = makeCombinedWebsocket(v2.websocket, v3.websocket)
  const server = Bun.serve<CoreWebSocketData>({
    hostname: "127.0.0.1", port: 0,
    fetch: (request, server) => {
      if (v3.tryUpgrade(request, server as never)) return
      const upgrade = v2.tryUpgrade(request, server as never)
      if (upgrade === true) return
      return upgrade instanceof Response ? upgrade : new Response("Not found", { status: 404 })
    },
    websocket: handler,
  })
  return { runtime, v2, v3, handler, server, close: async () => {
    void server.stop(true)
    await v3.shutdown()
    await v2.shutdown()
  } }
}

describe("assembled V2/V3 Bun listener", () => {
  test("preserves V2 binary requests and V3 handshakes across reconnects on the same listener", async () => {
    const listener = combinedListener()
    const sockets: WebSocket[] = []
    try {
      const v2 = connectSocket(`ws://127.0.0.1:${listener.server.port}/realtime`)
      sockets.push(v2.socket)
      await v2.opened
      const payload = ClientMessage.toBinary(ClientMessage.create({ id: 1n }))
      v2.socket.send(Uint8Array.from(payload).buffer)
      expect(await v2.next()).toEqual(payload)
      for (let attempt = 0; attempt < 2; attempt++) {
        const v3 = connectSocket(`ws://127.0.0.1:${listener.server.port}/realtime/v3`)
        sockets.push(v3.socket)
        await v3.opened
        let header: Uint8Array
        do header = Uint8Array.from(randomBytes(64)); while (!isValidObfuscatedHeader(header))
        const carrier = createObfuscatedClientHeader(header, 1)
        v3.socket.send(Uint8Array.from(carrier.wireHeader).buffer)
        const client = new InlineHandshakeClient({ rsaKeys: [listener.runtime.clientKey], randomBytes: (length) => Uint8Array.from(randomBytes(length)) })
        const ids = new MessageIdGenerator()
        let request = client.begin(false)
        let established = false
        for (let step = 0; step < 3; step++) {
          const record = encodeUnencryptedRecord(ids.next(Date.now(), step + 1, 0), request)
          v3.socket.send(Uint8Array.from(carrier.outbound.process(encodeAbridgedPacket(record))).buffer)
          const response = decodeAbridgedPacket(carrier.inbound.process(await v3.next()))
          const result = client.receive(decodeUnencryptedRecord(response).body)
          if ("request" in result) request = result.request
          else established = true
        }
        expect(established).toBeTrue()
        v3.socket.close()
      }
    } finally { for (const socket of sockets) socket.close(); await listener.close() }
  }, 20_000)

  test("does not negotiate deflate for either route even when the client offers it", async () => {
    const listener = combinedListener()
    try {
      for (const path of ["/realtime", "/realtime/v3"]) {
        const socket = createConnection({ host: "127.0.0.1", port: listener.server.port! })
        try {
          const headers = await new Promise<string>((resolve, reject) => {
            let data = ""
            socket.on("error", reject)
            socket.on("data", (bytes) => {
              data += bytes.toString("latin1")
              if (data.includes("\r\n\r\n")) resolve(data.slice(0, data.indexOf("\r\n\r\n")))
            })
            socket.on("connect", () => socket.write(
              `GET ${path} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n`,
            ))
          })
          expect(headers).toContain("101")
          expect(headers.toLowerCase()).not.toContain("sec-websocket-extensions")
        } finally { socket.destroy() }
      }
    } finally { await listener.close() }
  })

  test("bounds Bun's native output buffer and closes a slow reader at the shared limit", async () => {
    let dropped = false
    let queued = false
    let maximumBuffered = 0
    let finish!: () => void
    const completed = new Promise<void>((resolve) => { finish = resolve })
    const payload = new Uint8Array(1024 * 1024)
    const handler = makeCombinedWebsocket({
      message: () => {},
      open: (socket) => {
        // A client which never reads application frames must hit the native limit.
        for (let i = 0; i < 128; i++) {
          const result = socket.sendBinary(payload)
          maximumBuffered = Math.max(maximumBuffered, socket.getBufferedAmount())
          if (result === -1) queued = true
          if (result === 0) { dropped = true; break }
        }
      },
      close: () => finish(),
    }, { message: () => {} })
    const server = Bun.serve<CoreWebSocketData>({ hostname: "127.0.0.1", port: 0, websocket: handler,
      fetch: (request, server) => server.upgrade(request, { data: { id: "slow-reader" as never, closed: false, connection: undefined } }) ? undefined : new Response("failed"),
    })
    const socket = createConnection({ host: "127.0.0.1", port: server.port! })
    socket.pause()
    try {
      socket.on("connect", () => socket.write("GET /realtime HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"))
      await completed
      expect(queued).toBeTrue()
      expect(dropped).toBeTrue()
      // uWebSockets tests its threshold before the next write: allow one frame of overshoot.
      expect(maximumBuffered).toBeLessThanOrEqual(17 * 1024 * 1024 + 16)
    } finally { socket.destroy(); void server.stop(true) }
  }, 10_000)
})

const deferred = () => {
  let resolve!: () => void
  const promise = new Promise<void>((continuation) => { resolve = continuation })
  return { promise, resolve }
}

const upgrade = (
  transport: ReturnType<typeof makeInlineProtocolRealtimeTransport>,
  headers?: HeadersInit,
): InlineProtocolWebSocketData => {
  let data: InlineProtocolWebSocketData | undefined
  const server = {
    requestIP: () => ({ address: "127.0.0.1" }),
    upgrade: (_request: Request, options: { data: InlineProtocolWebSocketData }) => {
      data = options.data
      return true
    },
  } as unknown as Server<InlineProtocolWebSocketData>
  expect(transport.tryUpgrade(new Request("http://inline.test/realtime/v3", { headers }), server)).toBe(true)
  return data!
}

describe("Inline Protocol WebSocket carrier", () => {
  test("rejects frames on an existing socket as soon as drain begins", async () => {
    const transport = makeInlineProtocolRealtimeTransport(fixture())
    const data = upgrade(transport)
    const closes: number[] = []
    const socket = { data, close: (code: number) => { closes.push(code) }, sendBinary: () => 1 } as unknown as ServerWebSocket<InlineProtocolWebSocketData>
    transport.websocket.open?.(socket)
    transport.beginDrain()
    await transport.websocket.message(socket, Buffer.alloc(1))
    expect(closes).toEqual([1001])
    await transport.shutdown()
  })

  for (const outcome of [0, -1, "closed-under-pressure", "throw"] as const) {
    test(`handles carrier send outcome ${outcome} without replaying advanced bytes`, async () => {
      const runtime = fixture()
      const transport = makeInlineProtocolRealtimeTransport(runtime)
      const data = upgrade(transport)
      const sent: Uint8Array[] = []
      const closed: number[] = []
      const socket = { data, close: (code: number) => closed.push(code), sendBinary: (bytes: Uint8Array) => {
        sent.push(bytes.slice())
        if (outcome === "throw") throw new Error("synthetic write failure")
        return outcome === "closed-under-pressure" ? -1 : outcome
      } } as unknown as ServerWebSocket<InlineProtocolWebSocketData>
      transport.websocket.open?.(socket)
      let header: Uint8Array
      do header = Uint8Array.from(randomBytes(64)); while (!isValidObfuscatedHeader(header))
      const carrier = createObfuscatedClientHeader(header, 1)
      transport.websocket.message(socket, Buffer.from(carrier.wireHeader))
      await data.state!.queue
      const client = new InlineHandshakeClient({ rsaKeys: [runtime.clientKey], randomBytes: (length) => Uint8Array.from(randomBytes(length)) })
      const record = encodeUnencryptedRecord(new MessageIdGenerator().next(Date.now(), 1, 0), client.begin(false))
      transport.websocket.message(socket, Buffer.from(carrier.outbound.process(encodeAbridgedPacket(record))))
      await data.state!.queue
      if (outcome === -1 || outcome === "closed-under-pressure") {
        expect(closed).toEqual([])
        expect(data.state!.outboundQueuedRecords).toBe(1)
        expect(data.state!.outboundQueuedBytes).toBeGreaterThan(0)
        expect(data.state!.resumeOutbound).toBeDefined()
        if (outcome === "closed-under-pressure") transport.websocket.close?.(socket, 1001, "reader left")
        else transport.websocket.drain?.(socket)
      }
      await data.state!.outboundQueue
      expect(sent).toHaveLength(1)
      expect(data.state!.outboundQueuedBytes).toBe(0)
      expect(closed).toEqual(outcome === -1 || outcome === "closed-under-pressure" ? [] : [1002])
      if (outcome !== -1) {
        transport.websocket.message(socket, Buffer.from([1, 2, 3, 4]))
        await data.state!.queue
        expect(sent).toHaveLength(1)
        expect(data.state!.overloaded).toBeTrue()
      } else {
        const response = decodeAbridgedPacket(carrier.inbound.process(sent[0]!))
        expect(client.receive(decodeUnencryptedRecord(response).body)).toHaveProperty("request")
      }
      transport.websocket.close?.(socket, 1000, "done")
      await transport.shutdown()
    })
  }
  test("publishes only the safe public verification contract", async () => {
    const runtime = fixture()
    const transport = makeInlineProtocolRealtimeTransport(runtime)
    const response = transport.handleVerification(
      new Request("https://api.inline.chat/.well-known/inline-protocol"),
    )
    expect(response?.status).toBe(200)
    expect(response?.headers.get("cache-control")).toBe("no-store")
    expect(response?.headers.get("access-control-allow-origin")).toBe("*")
    const body = await response?.json() as Record<string, unknown>
    expect(body).toEqual({
      protocol: "Inline Protocol",
      protocolVersion: 1,
      applicationContract: "Realtime V3",
      applicationContractVersion: 3,
      status: "ready",
      serverTime: expect.any(Number),
      websocketPath: "/realtime/v3",
      rsaPublicKeyRing: [{
        modulus: Buffer.from(runtime.clientKey.modulus).toString("base64url"),
        exponent: Buffer.from(runtime.clientKey.exponent).toString("base64url"),
        fingerprint: runtime.clientKey.fingerprint.toString(),
      }],
    })
    expect(JSON.stringify(body)).not.toContain("private")
    expect(JSON.stringify(body)).not.toContain("pepper")
    expect(JSON.stringify(body)).not.toContain("kek")
    await transport.shutdown()
  })

  test("marks public verification degraded when the protocol clock is unsafe", async () => {
    let wall = 1_000_000
    let monotonic = 10_000
    const transport = makeInlineProtocolRealtimeTransport(fixture({}, new InlineProtocolClock({
      wallClock: () => wall,
      monotonicClock: () => monotonic,
    })))
    wall += 21_000
    monotonic += 500
    const response = transport.handleVerification(
      new Request("https://api.inline.chat/.well-known/inline-protocol"),
    )
    expect(response?.status).toBe(503)
    expect(await response?.json()).toMatchObject({ status: "degraded" })
    await transport.shutdown()
  })

  test("never negotiates WebSocket compression and closes malformed traffic without an oracle", async () => {
    const transport = makeInlineProtocolRealtimeTransport(fixture())
    const offeredCompression = new Request("http://inline.test/realtime/v3", {
      headers: { "sec-websocket-extensions": "permessage-deflate" },
    })
    expect(transport.rejectUnsupportedUpgrade(offeredCompression)).toBeUndefined()
    expect(transport.websocket.perMessageDeflate).toBe(false)
    const data = upgrade(transport, offeredCompression.headers)
    const closes: Array<[number, string]> = []
    const socket = {
      data,
      close: (code: number, reason: string) => closes.push([code, reason]),
      sendBinary: () => 0,
    } as unknown as ServerWebSocket<InlineProtocolWebSocketData>
    transport.websocket.open?.(socket)
    await transport.websocket.message(socket, "not binary")
    expect(closes).toEqual([[1002, "Protocol error"]])
    await transport.shutdown()
  })

  test("asks clients to replace a process-local authorization key forgotten on restart", async () => {
    const transport = makeInlineProtocolRealtimeTransport(fixture())
    const data = upgrade(transport)
    const closes: Array<[number, string]> = []
    const socket = {
      data,
      close: (code: number, reason: string) => closes.push([code, reason]),
      sendBinary: () => 0,
    } as unknown as ServerWebSocket<InlineProtocolWebSocketData>
    transport.websocket.open?.(socket)

    let headerBytes: Uint8Array
    do headerBytes = Uint8Array.from(randomBytes(64))
    while (!isValidObfuscatedHeader(headerBytes))
    const carrier = createObfuscatedClientHeader(headerBytes, 1)
    await transport.websocket.message(socket, Buffer.from(carrier.wireHeader))
    await data.state?.queue

    const forgottenKey = Uint8Array.from(randomBytes(256))
    const ping = encodePing(123n)
    const record = encryptRecord(forgottenKey, "client-to-server", {
      serverSalt: 456n,
      sessionId: 789n,
      messageId: new MessageIdGenerator().next(Date.now(), 1, 0),
      sequenceNumber: 0,
      body: ping,
    }, paddingFor(ping.length))
    await transport.websocket.message(socket, Buffer.from(
      carrier.outbound.process(encodeAbridgedPacket(record)),
    ))
    await data.state?.queue

    expect(closes).toEqual([[4401, "session_revoked"]])
    await transport.shutdown()
  })

  test("closes overloaded sockets before copying another inbound frame", async () => {
    const transport = makeInlineProtocolRealtimeTransport(fixture())
    const data = upgrade(transport)
    const closes: Array<[number, string]> = []
    const socket = {
      data,
      close: (code: number, reason: string) => closes.push([code, reason]),
      sendBinary: () => 0,
    } as unknown as ServerWebSocket<InlineProtocolWebSocketData>
    transport.websocket.open?.(socket)
    if (!data.state) throw new Error("Expected open connection state")
    data.state.inboundQueuedBytes = 32 * 1024 * 1024

    await transport.websocket.message(socket, Buffer.alloc(4))

    expect(closes).toEqual([[1013, "Realtime V3 overloaded"]])
    expect(data.state.inboundQueuedFrames).toBe(0)
    await transport.shutdown()
  })

  test("refuses new V3 upgrades after a dangerous server clock step", async () => {
    let wall = 1_000_000
    let monotonic = 10_000
    const runtime = fixture({}, new InlineProtocolClock({
      wallClock: () => wall,
      monotonicClock: () => monotonic,
    }))
    const transport = makeInlineProtocolRealtimeTransport(runtime)

    wall += 21_000
    monotonic += 500
    const request = new Request("http://inline.test/realtime/v3")

    expect(transport.rejectUnsupportedUpgrade(request)?.status).toBe(503)
    await transport.shutdown()
  })

  test("rejects handshakes above the per-IP admission limit before upgrading", async () => {
    const transport = makeInlineProtocolRealtimeTransport(fixture())
    const warnSpy = spyOn(realtimeV3Log, "warn")
    let upgrades = 0
    const server = {
      requestIP: () => ({ address: "127.0.0.1" }),
      upgrade: () => {
        upgrades += 1
        return true
      },
    } as unknown as Server<InlineProtocolWebSocketData>

    for (let attempt = 0; attempt < 8; attempt += 1) {
      const request = new Request("http://inline.test/realtime/v3")
      expect(transport.tryUpgrade(request, server)).toBe(true)
    }

    try {
      for (let attempt = 0; attempt < 3; attempt += 1) {
        const rejected = new Request("http://inline.test/realtime/v3")
        expect(transport.tryUpgrade(rejected, server)).toBe(false)
        expect(transport.rejectUnsupportedUpgrade(rejected)?.status).toBe(503)
      }
      expect(upgrades).toBe(8)
      const overloadWarnings = warnSpy.mock.calls.filter(
        ([message]) => message === "Inline Protocol V3 handshake admission overloaded",
      )
      expect(overloadWarnings).toHaveLength(1)
      expect(overloadWarnings[0]?.[1]).toMatchObject({
        activeHandshakes: 8,
        perIpCapacity: 8,
        suppressedCount: 0,
      })
    } finally {
      warnSpy.mockRestore()
      await transport.shutdown()
    }
  })

  test("rate-limits repeated handshake starts from one IP", async () => {
    const transport = makeInlineProtocolRealtimeTransport(fixture())
    let data: InlineProtocolWebSocketData | undefined
    const server = {
      requestIP: () => ({ address: "127.0.0.1" }),
      upgrade: (_request: Request, options: { data: InlineProtocolWebSocketData }) => {
        data = options.data
        return true
      },
    } as unknown as Server<InlineProtocolWebSocketData>

    for (let attempt = 0; attempt < 60; attempt += 1) {
      expect(transport.tryUpgrade(new Request("http://inline.test/realtime/v3"), server)).toBe(true)
      const socket = { data: data!, close: () => {} } as unknown as ServerWebSocket<InlineProtocolWebSocketData>
      transport.websocket.close?.(socket, 1000, "test close")
    }

    const rejected = new Request("http://inline.test/realtime/v3")
    expect(transport.tryUpgrade(rejected, server)).toBe(false)
    expect(transport.rejectUnsupportedUpgrade(rejected)?.status).toBe(503)
    await transport.shutdown()
  })

  test("carries the complete permanent authorization-key handshake as one packet per frame", async () => {
    const runtime = fixture()
    const transport = makeInlineProtocolRealtimeTransport(runtime)
    const data = upgrade(transport)
    const sent: Uint8Array[] = []
    const socket = {
      data,
      close: () => {},
      sendBinary: (bytes: Uint8Array) => {
        sent.push(bytes.slice())
        return bytes.length
      },
    } as unknown as ServerWebSocket<InlineProtocolWebSocketData>
    transport.websocket.open?.(socket)

    let headerBytes: Uint8Array
    do headerBytes = Uint8Array.from(randomBytes(64))
    while (!isValidObfuscatedHeader(headerBytes))
    const carrier = createObfuscatedClientHeader(headerBytes, 1)
    await transport.websocket.message(socket, Buffer.from(carrier.wireHeader))
    await data.state?.queue

    const client = new InlineHandshakeClient({
      rsaKeys: [runtime.clientKey],
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
    })
    const messageIds = new MessageIdGenerator()
    let request = client.begin(false)
    let established: EstablishedAuthorizationKey | undefined
    for (let step = 0; step < 3; step += 1) {
      const record = encodeUnencryptedRecord(messageIds.next(Date.now(), step + 1, 0), request)
      const frame = carrier.outbound.process(encodeAbridgedPacket(record))
      await transport.websocket.message(socket, Buffer.from(frame))
      await data.state?.queue
      const responseFrame = sent.shift()
      expect(responseFrame).toBeDefined()
      const responseRecord = decodeAbridgedPacket(carrier.inbound.process(responseFrame!))
      const result = client.receive(decodeUnencryptedRecord(responseRecord).body)
      if ("request" in result) request = result.request
      else established = result.established
    }
    expect(established?.temporary).toBe(false)
    expect(sent).toHaveLength(0)
    await transport.shutdown()
  }, 20_000)

  test("carries an authenticated native-login application request after the handshake", async () => {
    const runtime = fixture({
      authBegin: async () => ({
        challengeId: new Uint8Array(32).fill(7),
        delivery: 1,
        expiresAt: 1_700_000_600n,
        retryAfterSeconds: 60,
      }),
    })
    const transport = makeInlineProtocolRealtimeTransport(runtime)
    const data = upgrade(transport)
    const sent: Uint8Array[] = []
    const socket = {
      data,
      close: () => {},
      sendBinary: (bytes: Uint8Array) => { sent.push(bytes.slice()); return bytes.length },
    } as unknown as ServerWebSocket<InlineProtocolWebSocketData>
    transport.websocket.open?.(socket)

    let headerBytes: Uint8Array
    do headerBytes = Uint8Array.from(randomBytes(64))
    while (!isValidObfuscatedHeader(headerBytes))
    const carrier = createObfuscatedClientHeader(headerBytes, 1)
    await transport.websocket.message(socket, Buffer.from(carrier.wireHeader))
    await data.state?.queue

    const client = new InlineHandshakeClient({
      rsaKeys: [runtime.clientKey],
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
    })
    const ids = new MessageIdGenerator()
    let request = client.begin(false)
    let established: EstablishedAuthorizationKey | undefined
    for (let step = 0; step < 3; step += 1) {
      const frame = carrier.outbound.process(encodeAbridgedPacket(
        encodeUnencryptedRecord(ids.next(Date.now(), step + 1, 0), request),
      ))
      await transport.websocket.message(socket, Buffer.from(frame))
      await data.state?.queue
      const response = decodeAbridgedPacket(carrier.inbound.process(sent.shift()!))
      const result = client.receive(decodeUnencryptedRecord(response).body)
      if ("request" in result) request = result.request
      else established = result.established
    }
    if (!established) throw new Error("Handshake did not establish")

    const sessionId = 987654321n
    const messageId = ids.next(Date.now(), 10, 0)
    const applicationBody = encodeInlineInvoke(RealtimeV3Request.toBinary({
      body: {
        oneofKind: "authBegin",
        authBegin: { identifier: { oneofKind: "email", email: "v3@example.com" } },
      },
    }))
    const record = encryptRecord(established.key, "client-to-server", {
      serverSalt: established.serverSalt,
      sessionId,
      messageId,
      sequenceNumber: 1,
      body: applicationBody,
    }, paddingFor(applicationBody.length))
    await transport.websocket.message(socket, Buffer.from(
      carrier.outbound.process(encodeAbridgedPacket(record, true)),
    ))
    await data.state?.queue
    await Promise.all(data.state?.applicationTasks ?? [])
    await data.state?.queue
    await data.state?.outboundQueue

    const expectedQuickAck = decryptRecordWithMetadata(record, established.key, {
      direction: "client-to-server",
      sessionId,
      validServerSalts: new Set([established.serverSalt]),
      nowSeconds: Date.now() / 1_000,
    }).quickAckId
    const quickAck = decodeAbridgedFrame(carrier.inbound.process(sent.shift()!))
    expect(quickAck).toEqual({ kind: "quickAck", quickAckId: expectedQuickAck })

    const bodies = sent.splice(0).map((frame) => decryptRecord(
      decodeAbridgedPacket(carrier.inbound.process(frame)),
      established!.key,
      {
        direction: "server-to-client",
        sessionId,
        validServerSalts: new Set([established!.serverSalt]),
        nowSeconds: Date.now() / 1_000,
      },
    ).body)
    const resultBody = bodies.find((body) => serviceConstructor(body) === ServiceConstructor.rpcResult)
    expect(resultBody).toBeDefined()
    const application = decodeInlineApplicationObject(decodeRpcResult(resultBody!).result)
    expect(application.kind).toBe("result")
    if (application.kind !== "result") throw new Error("Expected application result")
    const response = RealtimeV3Response.fromBinary(application.payload)
    expect(response.body.oneofKind).toBe("authBegin")
    if (response.body.oneofKind === "authBegin") {
      expect(response.body.authBegin.challengeId).toEqual(new Uint8Array(32).fill(7))
    }
    await transport.shutdown()
  }, 20_000)

  test("admits independent application RPCs while earlier handlers are still running", async () => {
    const runtime = fixture()
    const key = Uint8Array.from(randomBytes(256))
    const keyId = authKeyId(key)
    const serverSalt = 0x1020_3040_5060_7080n
    const sessionId = 0x1122_3344n
    runtime.authorizationKeys.values.set(bytesToHex(keyId), {
      key,
      keyId,
      temporary: true,
      expiresAt: Math.floor(Date.now() / 1_000) + 600,
      currentServerSalt: serverSalt,
      binding: {
        permanentAuthKeyId: Uint8Array.from(randomBytes(8)),
        temporarySessionId: sessionId,
        nonce: 1n,
        expiresAt: Math.floor(Date.now() / 1_000) + 600,
        userId: 42,
        accountSessionId: 84,
      },
    })
    const firstGate = deferred()
    const secondGate = deferred()
    const thirdGate = deferred()
    const started: number[] = []
    let runtimeClosed = false
    runtime.close = () => { runtimeClosed = true }
    const transport = makeInlineProtocolRealtimeTransport(runtime, {
      applicationDispatcherFactory: () => ({
        dispatch: async ({ payload, markExecutionStarted }) => {
          markExecutionStarted()
          const value = payload[0]!
          started.push(value)
          if (value === 1) await firstGate.promise
          if (value === 2) await secondGate.promise
          if (value === 3) await thirdGate.promise
          return { kind: "result", payload: Uint8Array.of(value + 10) }
        },
      }),
    })
    const data = upgrade(transport)
    const sent: Uint8Array[] = []
    let outputAvailable = deferred()
    const socket = {
      data,
      close: () => {},
      sendBinary: (bytes: Uint8Array) => {
        sent.push(bytes.slice())
        outputAvailable.resolve()
        return bytes.length
      },
    } as unknown as ServerWebSocket<InlineProtocolWebSocketData>
    transport.websocket.open?.(socket)

    let headerBytes: Uint8Array
    do headerBytes = Uint8Array.from(randomBytes(64))
    while (!isValidObfuscatedHeader(headerBytes))
    const carrier = createObfuscatedClientHeader(headerBytes, 1)
    await transport.websocket.message(socket, Buffer.from(carrier.wireHeader))
    await data.state?.queue

    const ids = new MessageIdGenerator()
    const firstMessageId = ids.next(Date.now(), 1, 0)
    const secondMessageId = ids.next(Date.now(), 2, 0)
    const pingMessageId = ids.next(Date.now(), 3, 0)
    const thirdMessageId = ids.next(Date.now(), 4, 0)
    const sendInvoke = async (messageId: bigint, sequenceNumber: number, value: number): Promise<void> => {
      const body = encodeInlineInvoke(Uint8Array.of(value))
      const record = encryptRecord(key, "client-to-server", {
        serverSalt, sessionId, messageId, sequenceNumber, body,
      }, paddingFor(body.length))
      await transport.websocket.message(socket, Buffer.from(
        carrier.outbound.process(encodeAbridgedPacket(record)),
      ))
      await data.state?.queue
      await data.state?.outboundQueue
    }
    const drainBodies = (): Uint8Array[] => {
      const frames = sent.splice(0)
      outputAvailable = deferred()
      return frames.map((frame) => {
        const decoded = decodeAbridgedFrame(carrier.inbound.process(frame))
        if (decoded.kind !== "packet") throw new Error("Expected an encrypted packet")
        return decryptRecord(decoded.payload, key, {
          direction: "server-to-client",
          sessionId,
          validServerSalts: new Set([serverSalt]),
          nowSeconds: Date.now() / 1_000,
        }).body
      })
    }
    const waitForOutput = async (): Promise<void> => {
      if (sent.length === 0) await outputAvailable.promise
    }

    await sendInvoke(firstMessageId, 1, 1)
    await sendInvoke(secondMessageId, 3, 2)
    const pingId = 0x0102_0304_0506_0708n
    const pingBody = encodePing(pingId)
    const pingRecord = encryptRecord(key, "client-to-server", {
      serverSalt,
      sessionId,
      messageId: pingMessageId,
      sequenceNumber: 4,
      body: pingBody,
    }, paddingFor(pingBody.length))
    await transport.websocket.message(socket, Buffer.from(
      carrier.outbound.process(encodeAbridgedPacket(pingRecord)),
    ))
    await data.state?.queue
    await data.state?.outboundQueue
    expect(started).toEqual([1, 2])
    const immediateBodies = drainBodies()
    expect(immediateBodies.some((body) => serviceConstructor(body) === ServiceConstructor.rpcResult)).toBeFalse()
    const acknowledged = immediateBodies
      .filter((body) => serviceConstructor(body) === ServiceConstructor.msgsAck)
      .flatMap((body) => decodeMsgsAck(body))
    expect(acknowledged).toContain(firstMessageId)
    expect(acknowledged).toContain(secondMessageId)
    const pong = immediateBodies.find((body) => serviceConstructor(body) === ServiceConstructor.pong)
    expect(pong).toBeDefined()
    expect(readInt64LE(pong!, 4)).toBe(pingMessageId)
    expect(readInt64LE(pong!, 12)).toBe(pingId)

    secondGate.resolve()
    await waitForOutput()
    const secondResult = drainBodies()
      .find((body) => serviceConstructor(body) === ServiceConstructor.rpcResult)
    expect(secondResult).toBeDefined()
    expect(decodeRpcResult(secondResult!).requestMessageId).toBe(secondMessageId)

    firstGate.resolve()
    await waitForOutput()
    const firstResult = drainBodies()
      .find((body) => serviceConstructor(body) === ServiceConstructor.rpcResult)
    expect(firstResult).toBeDefined()
    expect(decodeRpcResult(firstResult!).requestMessageId).toBe(firstMessageId)

    await sendInvoke(thirdMessageId, 5, 3)
    expect(started).toEqual([1, 2, 3])
    drainBodies()
    transport.websocket.close?.(socket, 1000, "test close")
    const sentAfterClose = sent.length
    let shutdownFinished = false
    const shutdown = transport.shutdown().then(() => { shutdownFinished = true })
    await Promise.resolve()
    expect(shutdownFinished).toBeFalse()
    expect(runtimeClosed).toBeFalse()
    thirdGate.resolve()
    await shutdown
    expect(shutdownFinished).toBeTrue()
    expect(runtimeClosed).toBeTrue()
    expect(sent).toHaveLength(sentAfterClose)

  })

  test("does not register a compatibility connection after the socket closes", async () => {
    let authorize: ((authorization: ServerApplicationAuthorization) => boolean) | undefined
    const transport = makeInlineProtocolRealtimeTransport(fixture(), {
      applicationDispatcherFactory: ({ onAuthorized }) => {
        authorize = onAuthorized
        return {
          dispatch: async () => ({ kind: "result", payload: Uint8Array.of(1) }),
        }
      },
    })
    const data = upgrade(transport)
    const socket = {
      data,
      close: () => {},
      sendBinary: (bytes: Uint8Array) => bytes.length,
    } as unknown as ServerWebSocket<InlineProtocolWebSocketData>
    transport.websocket.open?.(socket)
    const register = authorize
    if (!register) throw new Error("Expected authorization callback")
    const addConnection = spyOn(connectionManager, "addConnection")
    const authenticateConnection = spyOn(connectionManager, "authenticateConnection")

    try {
      transport.websocket.close?.(socket, 1000, "test close")
      expect(register({
        authKeyId: Uint8Array.of(1, 2, 3, 4, 5, 6, 7, 8),
        permanent: false,
        temporaryBound: true,
        userId: 42,
        accountSessionId: 84,
      })).toBeFalse()

      expect(addConnection).not.toHaveBeenCalled()
      expect(authenticateConnection).not.toHaveBeenCalled()
      expect(connectionManager.getConnection(data.id)).toBeUndefined()
      expect(data.state?.registered).toBeFalse()
    } finally {
      addConnection.mockRestore()
      authenticateConnection.mockRestore()
      connectionManager.removeConnection(data.id)
      await transport.shutdown()
    }
  })

  test("does not register a compatibility connection after shutdown begins", async () => {
    let authorize: ((authorization: ServerApplicationAuthorization) => boolean) | undefined
    const transport = makeInlineProtocolRealtimeTransport(fixture(), {
      applicationDispatcherFactory: ({ onAuthorized }) => {
        authorize = onAuthorized
        return {
          dispatch: async () => ({ kind: "result", payload: Uint8Array.of(1) }),
        }
      },
    })
    const data = upgrade(transport)
    let closeCount = 0
    const socket = {
      data,
      close: () => { closeCount += 1 },
      sendBinary: (bytes: Uint8Array) => bytes.length,
    } as unknown as ServerWebSocket<InlineProtocolWebSocketData>
    transport.websocket.open?.(socket)
    const register = authorize
    if (!register) throw new Error("Expected authorization callback")
    const addConnection = spyOn(connectionManager, "addConnection")
    const authenticateConnection = spyOn(connectionManager, "authenticateConnection")

    let shutdown: Promise<void> | undefined
    try {
      shutdown = transport.shutdown()
      expect(closeCount).toBe(1)
      expect(data.closed).toBeFalse()
      expect(register({
        authKeyId: Uint8Array.of(1, 2, 3, 4, 5, 6, 7, 8),
        permanent: false,
        temporaryBound: true,
        userId: 42,
        accountSessionId: 84,
      })).toBeFalse()

      expect(addConnection).not.toHaveBeenCalled()
      expect(authenticateConnection).not.toHaveBeenCalled()
      expect(connectionManager.getConnection(data.id)).toBeUndefined()
      expect(data.state?.registered).toBeFalse()
    } finally {
      await shutdown
      addConnection.mockRestore()
      authenticateConnection.mockRestore()
      connectionManager.removeConnection(data.id)
    }
  })

  test("closes V3 registration when a session revocation wins the admission race", async () => {
    let authorize: ((authorization: ServerApplicationAuthorization) => boolean) | undefined
    const transport = makeInlineProtocolRealtimeTransport(fixture(), {
      applicationDispatcherFactory: ({ onAuthorized }) => {
        authorize = onAuthorized
        return { dispatch: async () => ({ kind: "result", payload: Uint8Array.of(1) }) }
      },
    })
    const data = upgrade(transport)
    const closes: Array<{ code: number; reason: string }> = []
    const socket = {
      data,
      close: (code: number, reason: string) => { closes.push({ code, reason }) },
      sendBinary: (bytes: Uint8Array) => bytes.length,
    } as unknown as ServerWebSocket<InlineProtocolWebSocketData>
    transport.websocket.open?.(socket)
    const register = authorize
    if (!register) throw new Error("Expected authorization callback")

    try {
      sessionAuthority.invalidate({ userId: 42, sessionId: 84 })
      expect(register({
        authKeyId: Uint8Array.of(1, 2, 3, 4, 5, 6, 7, 8),
        permanent: false,
        temporaryBound: true,
        userId: 42,
        accountSessionId: 84,
      })).toBeFalse()

      expect(closes).toEqual([{ code: 4401, reason: "session_revoked" }])
      expect(connectionManager.getConnection(data.id)).toBeUndefined()
      expect(data.state?.registered).toBeFalse()
    } finally {
      sessionAuthority.stop()
      connectionManager.removeConnection(data.id)
      await transport.shutdown()
    }
  })

  test("reserves compatibility fanout bytes before queueing retained updates", async () => {
    const runtime = fixture()
    const key = Uint8Array.from(randomBytes(256))
    const keyId = authKeyId(key)
    const serverSalt = 0x1020_3040_5060_7080n
    const sessionId = 0x5566_7788n
    runtime.authorizationKeys.values.set(bytesToHex(keyId), {
      key,
      keyId,
      temporary: true,
      expiresAt: Math.floor(Date.now() / 1_000) + 600,
      currentServerSalt: serverSalt,
      binding: {
        permanentAuthKeyId: Uint8Array.from(randomBytes(8)),
        temporarySessionId: sessionId,
        nonce: 1n,
        expiresAt: Math.floor(Date.now() / 1_000) + 600,
        userId: 42,
        accountSessionId: 84,
      },
    })
    const legacyUpdate = ServerProtocolMessage.toBinary({
      id: 1n,
      body: {
        oneofKind: "message",
        message: {
          payload: {
            oneofKind: "update",
            update: { updates: [] },
          },
        },
      },
    })
    const decodedLegacy = ServerProtocolMessage.fromBinary(legacyUpdate)
    if (decodedLegacy.body.oneofKind !== "message") throw new Error("Expected legacy update message")
    const retainedBytes = RealtimeV3Update.toBinary({ message: decodedLegacy.body.message }).length
    const transport = makeInlineProtocolRealtimeTransport(runtime, {
      maximumBufferedApplicationUpdateBytes: retainedBytes,
      applicationDispatcherFactory: ({ onAuthorized }) => ({
        dispatch: async ({ authorization, markExecutionStarted }) => {
          markExecutionStarted()
          onAuthorized(authorization)
          return { kind: "result", payload: Uint8Array.of(1) }
        },
      }),
    })
    const data = upgrade(transport)
    const closes: Array<[number, string]> = []
    const socket = {
      data,
      close: (code: number, reason: string) => closes.push([code, reason]),
      sendBinary: (bytes: Uint8Array) => bytes.length,
    } as unknown as ServerWebSocket<InlineProtocolWebSocketData>
    transport.websocket.open?.(socket)

    let headerBytes: Uint8Array
    do headerBytes = Uint8Array.from(randomBytes(64))
    while (!isValidObfuscatedHeader(headerBytes))
    const carrier = createObfuscatedClientHeader(headerBytes, 1)
    await transport.websocket.message(socket, Buffer.from(carrier.wireHeader))
    await data.state?.queue

    const application = encodeInlineInvoke(Uint8Array.of(1))
    const record = encryptRecord(key, "client-to-server", {
      serverSalt,
      sessionId,
      messageId: new MessageIdGenerator().next(Date.now(), 1, 0),
      sequenceNumber: 1,
      body: application,
    }, paddingFor(application.length))
    await transport.websocket.message(socket, Buffer.from(
      carrier.outbound.process(encodeAbridgedPacket(record)),
    ))
    await data.state?.queue
    await Promise.all(data.state?.applicationTasks ?? [])
    await data.state?.queue
    await data.state?.outboundQueue

    const compatibility = connectionManager.getConnection(data.id)?.ws.raw
    expect(compatibility).toBeDefined()
    if (!data.state || !compatibility) throw new Error("Expected registered V3 compatibility connection")
    const outboundGate = deferred()
    data.state.outboundQueue = outboundGate.promise

    expect(compatibility.sendBinary(legacyUpdate, true)).toBe(legacyUpdate.length)
    expect(compatibility.sendBinary(legacyUpdate, true)).toBe(0)
    expect(closes).toContainEqual([1013, "Realtime V3 overloaded"])

    outboundGate.resolve()
    await data.state.queue
    await data.state.outboundQueue
    transport.websocket.close?.(socket, 1000, "test close")
    await transport.shutdown()
  })

})
