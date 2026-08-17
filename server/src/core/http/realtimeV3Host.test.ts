import { describe, expect, test } from "bun:test"
import { constants, generateKeyPairSync, privateDecrypt, randomBytes } from "node:crypto"
import type { Server, ServerWebSocket } from "bun"
import {
  InlineHandshakeClient,
  MessageIdGenerator,
  ServiceConstructor,
  bytesToHex,
  createObfuscatedClientHeader,
  decodeAbridgedFrame,
  decodeAbridgedPacket,
  decodeInlineApplicationObject,
  decodeRpcResult,
  decryptRecord,
  decryptRecordWithMetadata,
  encodeAbridgedPacket,
  encodeInlineInvoke,
  encryptRecord,
  isValidObfuscatedHeader,
  serviceConstructor,
} from "@inline-chat/protocol/secure"
import { RealtimeV3Request, RealtimeV3Response } from "@inline-chat/protocol/core"
import {
  decodeUnencryptedRecord,
  encodeUnencryptedRecord,
  makeRsaPublicKey,
  type EstablishedAuthorizationKey,
  type LoadedServerAuthorizationKey,
  type ServerAuthorizationKeyRepository,
  type ServerReplayRepository,
} from "@inline-chat/protocol/server"
import {
  makeInlineProtocolRealtimeTransport,
  type InlineProtocolRuntime,
  type InlineProtocolWebSocketData,
} from "./realtimeV3Host"
import { InlineProtocolClock } from "@in/server/modules/inlineProtocol/clockHealth"

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
): InlineProtocolRuntime & { clientKey: ReturnType<typeof makeRsaPublicKey> } => {
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
})
