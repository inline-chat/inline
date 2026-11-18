import { randomBytes } from "node:crypto"
import { gzipSync } from "node:zlib"
import { afterEach, describe, expect, it } from "vitest"
import { Method, RealtimeV3Update } from "@inline-chat/protocol/core"
import {
  acceptObfuscatedClientHeader,
  decodeAbridgedFrame,
  decodeReqPqMulti,
  decodeUnencryptedRecord,
  encodeAbridgedPacket,
  encodeResPq,
  encodeUnencryptedRecord,
  type ObfuscatedServerHeader,
} from "@inline-chat/protocol/secure"
import { nodeAesBackend } from "@inline-chat/protocol/secure/node"
import {
  InlineProtocolSocketState,
  InlineProtocolV3Connection,
  InlineProtocolV3Error,
  decodeBase64Url,
  makeCachedPureAesBackend,
  makePureAesBackend,
  type InlineProtocolRuntime,
} from "@inline-chat/protocol/secure/connection"
import { browserGunzip, browserRandomBytes, createBrowserInlineProtocolRuntime } from "./v3-browser-runtime"
import { LoopbackPeer, SERVER_ERROR_TEXT, settle } from "./v3-test-peer"

const open: InlineProtocolV3Connection[] = []
afterEach(async () => {
  await Promise.all(open.splice(0).map((connection) => connection.close()))
})

const track = (connection: InlineProtocolV3Connection) => {
  open.push(connection)
  return connection
}

/** A permanent key bound through authUpgradeSession, then a temporary key bound to it. */
const authenticated = async (peer: LoopbackPeer, onUpdate?: (update: RealtimeV3Update) => void) => {
  const runtime = createBrowserInlineProtocolRuntime({ WebSocket: peer.WebSocket })
  peer.validBearerTokens.add("bearer-1")
  const startedPermanent = performance.now()
  const permanent = track(await InlineProtocolV3Connection.connect({
    url: "wss://loopback/realtime/v3", runtime, rsaPublicKeys: peer.publicKeys,
  }))
  const permanentHandshakeMs = performance.now() - startedPermanent
  const upgraded = await permanent.authUpgradeSession("bearer-1")
  expect(upgraded.state.oneofKind).toBe("authorized")
  const startedTemporary = performance.now()
  const temporary = track(await InlineProtocolV3Connection.connect({
    url: "wss://loopback/realtime/v3", runtime, rsaPublicKeys: peer.publicKeys, temporary: true,
    ...(onUpdate ? { onUpdate } : {}),
  }))
  await temporary.bindTemporary(permanent.authorization)
  const temporaryHandshakeMs = performance.now() - startedTemporary
  return { runtime, permanent, temporary, permanentHandshakeMs, temporaryHandshakeMs }
}

describe("portable V3 connection on the browser runtime", () => {
  it("handshakes, binds a temporary key and answers the first RPC against the real server session", async () => {
    const peer = new LoopbackPeer()
    const { permanent, temporary, permanentHandshakeMs, temporaryHandshakeMs } = await authenticated(peer)

    expect(permanent.authorization.temporary).toBe(false)
    expect(temporary.authorization.temporary).toBe(true)
    expect(temporary.authorization.expiresAt).toBeGreaterThan(Date.now() / 1_000)
    await expect(temporary.callRpc({ method: Method.GET_ME, input: { oneofKind: "getMe", getMe: {} } }))
      .resolves.toMatchObject({ oneofKind: "getMe", getMe: { user: { id: 7n } } })
    // Omitted fields take proto defaults.
    await expect(temporary.callRpc({ method: Method.GET_CHATS, input: { oneofKind: "getChats", getChats: {} } }))
      .resolves.toEqual({ oneofKind: undefined })
    await expect(temporary.ping()).resolves.toBeUndefined()
    expect(peer.receivedRpcs.map((call) => call.method)).toEqual([Method.GET_ME, Method.GET_CHATS])
    // Measured cost of a full handshake (RSA + DH) in Node with the cached pure-JS AES; recorded in the README.
    expect(permanentHandshakeMs).toBeGreaterThan(0)
    expect(temporaryHandshakeMs).toBeGreaterThan(0)
  }, 30_000)

  it("inflates a gzip_packed update through DecompressionStream", async () => {
    const peer = new LoopbackPeer()
    const updates: RealtimeV3Update[] = []
    const { temporary } = await authenticated(peer, (update) => updates.push(update))
    await temporary.ping()
    const update: RealtimeV3Update = { message: { payload: { oneofKind: "update", update: { updates: [] } } } }
    peer.pushGzippedUpdate(update)
    peer.pushUpdate({ message: { payload: { oneofKind: undefined } } })
    await expect.poll(() => updates.length).toBe(2)
    // The compressed record is delivered before the plain one sent after it.
    expect(updates[0]).toEqual(update)
    expect(updates[1]).toEqual({ message: { payload: { oneofKind: undefined } } })
  }, 30_000)

  it("closes with a code browsers accept when the receive loop fails", async () => {
    const peer = new LoopbackPeer()
    const closes: Error[] = []
    const runtime = createBrowserInlineProtocolRuntime({ WebSocket: peer.WebSocket })
    peer.validBearerTokens.add("bearer-1")
    const permanent = track(await InlineProtocolV3Connection.connect({
      url: "wss://loopback/realtime/v3", runtime, rsaPublicKeys: peer.publicKeys,
      onClose: (error) => closes.push(error),
    }))
    // A frame the carrier cannot authenticate fails the loop; its 1011 close must not throw in a browser.
    peer.lastConnection!.client.deliver(Uint8Array.from(randomBytes(64)))
    await expect.poll(() => closes.length).toBe(1)
    const calls = (peer.lastConnection!.client as unknown as { closeCalls: Array<{ code?: number }> }).closeCalls
    expect(calls.at(-1)?.code).toBe(1000)
    await expect(permanent.ping()).rejects.toBeInstanceOf(InlineProtocolV3Error)
  }, 30_000)

  it("rejects a pinned key whose fingerprint does not match", async () => {
    const peer = new LoopbackPeer()
    const runtime = createBrowserInlineProtocolRuntime({ WebSocket: peer.WebSocket })
    await expect(InlineProtocolV3Connection.connect({
      url: "wss://loopback/realtime/v3", runtime,
      rsaPublicKeys: [{ ...peer.publicKeys[0]!, fingerprint: "1" }],
    })).rejects.toMatchObject({ code: "invalid-key" })
    expect(peer.connections).toHaveLength(0)
  })

  it("fails the open when the socket is refused", async () => {
    const peer = new LoopbackPeer()
    peer.refuse = true
    const runtime = createBrowserInlineProtocolRuntime({ WebSocket: peer.WebSocket })
    await expect(InlineProtocolV3Connection.connect({
      url: "wss://loopback/realtime/v3", runtime, rsaPublicKeys: peer.publicKeys,
    })).rejects.toMatchObject({ code: "closed" })
    await settle()
  })
})

const URL = "wss://loopback/realtime/v3"
const update = (n: number): RealtimeV3Update => ({
  message: { payload: { oneofKind: "update", update: { updates: [{ seq: n, update: { oneofKind: undefined } }] } } },
})
const updateSeq = (value: RealtimeV3Update) =>
  value.message?.payload.oneofKind === "update" ? value.message.payload.update.updates[0]?.seq : undefined

describe("records the client receives (security review)", () => {
  it("drops a replayed server record: a repeated update is delivered once", async () => {
    const peer = new LoopbackPeer()
    const updates: RealtimeV3Update[] = []
    const { temporary } = await authenticated(peer, (value) => updates.push(value))
    await temporary.ping()
    peer.pushUpdate(update(1))
    const genuine = peer.lastConnection!.sent.at(-1)!
    await expect.poll(() => updates.length).toBe(1)
    peer.inject(genuine)
    peer.inject(genuine)
    await temporary.ping()
    expect(updates.map(updateSeq)).toEqual([1])
  }, 30_000)

  it("accepts genuine records that arrive out of order inside the window", async () => {
    const peer = new LoopbackPeer()
    const updates: RealtimeV3Update[] = []
    const { temporary } = await authenticated(peer, (value) => updates.push(value))
    await temporary.ping()
    const first = peer.record(LoopbackPeer.update(update(1)))
    const second = peer.record(LoopbackPeer.update(update(2)))
    peer.inject(second)
    peer.inject(first)
    await temporary.ping()
    expect(updates.map(updateSeq)).toEqual([2, 1])
  }, 30_000)

  it("refuses to roll back the server salt or rewind the authenticated clock with an older record", async () => {
    const peer = new LoopbackPeer()
    const updates: RealtimeV3Update[] = []
    const { temporary } = await authenticated(peer, (value) => updates.push(value))
    await temporary.ping()
    const serverSalt = temporary.authorization.serverSalt
    const older = peer.serverMessageId()
    const barrier = peer.serverMessageId()
    const newer = peer.serverMessageId(Date.now() + 20_000)
    // The newest record announces a salt; an older one (held back by whoever sits on the wire) tries to restore a stale one.
    peer.inject(peer.record(LoopbackPeer.newSessionCreated(serverSalt + 1n), { messageId: newer, sequenceNumber: 1_003 }))
    peer.inject(peer.record(LoopbackPeer.newSessionCreated(serverSalt + 2n), { messageId: older, sequenceNumber: 1_005 }))
    peer.inject(peer.record(LoopbackPeer.update(update(9)), { messageId: barrier }))
    await expect.poll(() => updates.length).toBe(1)
    expect(temporary.authorization.serverSalt).toBe(serverSalt + 1n)

    // The clock stays at the newest record: the next request is stamped at or after it.
    const before = peer.lastConnection!.clientRecords.length
    await temporary.ping()
    const stamped = peer.lastConnection!.clientRecords[before]!
    expect(stamped.messageId >> 32n).toBeGreaterThanOrEqual(newer >> 32n)
    // The server did not know that salt; its bad_server_salt notice is accepted and the ping resent with the real one.
    expect(stamped.serverSalt).toBe(serverSalt + 1n)
    expect(temporary.authorization.serverSalt).toBe(serverSalt)
    expect(peer.lastConnection!.clientRecords.at(-1)!.serverSalt).toBe(serverSalt)
  }, 30_000)

  it("follows a server salt rotation it did not see (bad_server_salt) on a cached key", async () => {
    const peer = new LoopbackPeer()
    const { runtime, temporary } = await authenticated(peer)
    const authorization = temporary.authorization
    await temporary.close()
    // Two rotations: the cached salt is neither the server's current nor its previous one.
    await peer.keys.rotateServerSalt(authorization.keyId, authorization.serverSalt + 10n)
    await peer.keys.rotateServerSalt(authorization.keyId, authorization.serverSalt + 11n)
    const cached = track(await InlineProtocolV3Connection.connect({ url: URL, runtime, rsaPublicKeys: [], authorization }))
    await cached.probeTemporaryAuthorization()
    expect(cached.authorization.serverSalt).toBe(authorization.serverSalt + 11n)
    await expect(cached.callRpc({ method: Method.GET_ME, input: { oneofKind: "getMe", getMe: {} } }))
      .resolves.toMatchObject({ oneofKind: "getMe" })
  }, 30_000)

  it.each([
    ["10 minutes behind", -10 * 60_000],
    ["10 minutes ahead", 10 * 60_000],
    ["20 hours ahead", 20 * 3_600_000],
  ])("reconnects with a cached key on a device clock %s", async (_label, skew) => {
    const peer = new LoopbackPeer()
    const { temporary } = await authenticated(peer)
    const skewed = createBrowserInlineProtocolRuntime({
      WebSocket: peer.WebSocket,
      clock: { wallMilliseconds: () => Date.now() + skew, monotonicMilliseconds: () => performance.now() },
    })
    const cached = track(await InlineProtocolV3Connection.connect({
      url: URL, runtime: skewed, rsaPublicKeys: [], authorization: temporary.authorization,
    }))
    await cached.probeTemporaryAuthorization()
    expect(cached.temporaryAuthorizationNeedsRotation()).toBe(false)
    await expect(cached.callRpc({ method: Method.GET_ME, input: { oneofKind: "getMe", getMe: {} } }))
      .resolves.toMatchObject({ oneofKind: "getMe" })
  }, 30_000)

  it("fails on an authenticated record outside the time window without exposing its plaintext", async () => {
    const peer = new LoopbackPeer()
    const closes: Error[] = []
    const runtime = createBrowserInlineProtocolRuntime({ WebSocket: peer.WebSocket })
    const connection = track(await InlineProtocolV3Connection.connect({
      url: URL, runtime, rsaPublicKeys: peer.publicKeys, onClose: (error) => closes.push(error),
    }))
    await connection.ping()
    peer.inject(peer.record(LoopbackPeer.update(update(5)), { messageId: peer.serverMessageId(Date.now() - 400_000) }))
    await expect.poll(() => closes.length).toBe(1)
    const error = closes[0]!
    expect(error).toBeInstanceOf(InlineProtocolV3Error)
    expect(error).toMatchObject({ code: "protocol" })
    expect(error.cause).toBeUndefined()
    expect(Object.keys(error)).not.toContain("fields")
    expect(JSON.stringify(Object.getOwnPropertyNames(error))).not.toContain("fields")
  }, 30_000)

  it("does not copy server error text into its errors", async () => {
    const peer = new LoopbackPeer()
    const { temporary } = await authenticated(peer)
    // A temporary key may not upgrade a session; the server answers with an RPC error carrying text.
    const error = await temporary.authUpgradeSession("bearer-1").catch((value: unknown) => value)
    expect(error).toBeInstanceOf(InlineProtocolV3Error)
    expect((error as Error).message).not.toContain(SERVER_ERROR_TEXT)
    expect((error as Error).message).toContain("401")
  }, 30_000)
})

/** A server that answers the first handshake request with a chosen `pq` and nothing else. */
const pqServer = (pq: Uint8Array, fingerprint: bigint) => {
  let sent = 0
  const runtime: InlineProtocolRuntime = {
    randomBytes: browserRandomBytes,
    gunzip: browserGunzip,
    webSocket: (_url, handlers) => {
      let carrier: ObfuscatedServerHeader | undefined
      let state: number = InlineProtocolSocketState.connecting
      queueMicrotask(() => {
        state = InlineProtocolSocketState.open
        handlers.onOpen()
      })
      return {
        get readyState() { return state },
        bufferedAmount: 0,
        send: (data) => {
          sent += 1
          if (!carrier) {
            carrier = acceptObfuscatedClientHeader(data, 1)
            return
          }
          const frame = decodeAbridgedFrame(carrier.inbound.process(data))
          if (frame.kind !== "packet") return
          const { nonce } = decodeReqPqMulti(decodeUnencryptedRecord(frame.payload).body)
          const response = encodeUnencryptedRecord(
            (BigInt(Math.floor(Date.now() / 1_000)) << 32n) | 1n,
            encodeResPq(nonce, Uint8Array.from(randomBytes(16)), pq, [fingerprint]),
          )
          const wire = carrier.outbound.process(encodeAbridgedPacket(response))
          queueMicrotask(() => handlers.onMessage(wire))
        },
        close: (code, reason) => {
          state = InlineProtocolSocketState.closed
          queueMicrotask(() => handlers.onClose(code ?? 1005, reason ?? ""))
        },
      }
    },
  }
  return { runtime, sent: () => sent }
}

describe("handshake work bound (security review)", () => {
  const fingerprint = () => BigInt(new LoopbackPeer().publicKeys[0]!.fingerprint)

  it("fails the handshake promptly when the unauthenticated pq cannot be factored", async () => {
    // 2^63 - 25 is prime: the unbounded factoring spent about 15 s on it, blocking the worker.
    const server = pqServer(Uint8Array.from(Buffer.from("7fffffffffffffe7", "hex")), fingerprint())
    const peer = new LoopbackPeer()
    const started = performance.now()
    await expect(InlineProtocolV3Connection.connect({ url: URL, runtime: server.runtime, rsaPublicKeys: peer.publicKeys }))
      .rejects.toMatchObject({ code: "protocol" })
    expect(performance.now() - started).toBeLessThan(2_000)
  }, 60_000)

  it.each([
    ["longer than 8 bytes", "0117ed48941a08f981"],
    ["empty", ""],
  ])("rejects a pq %s before factoring", async (_label, hex) => {
    const server = pqServer(Uint8Array.from(Buffer.from(hex, "hex")), fingerprint())
    const peer = new LoopbackPeer()
    await expect(InlineProtocolV3Connection.connect({ url: URL, runtime: server.runtime, rsaPublicKeys: peer.publicKeys }))
      .rejects.toMatchObject({ code: "protocol" })
  }, 30_000)

  it("still factors the server's real challenge", async () => {
    const peer = new LoopbackPeer()
    await expect(authenticated(peer)).resolves.toBeDefined()
  }, 30_000)
})

describe("browser runtime pieces", () => {
  it("gunzips and stops at the output limit", async () => {
    const plain = new Uint8Array(64 * 1024).fill(0x41)
    const packed = Uint8Array.from(gzipSync(plain))
    await expect(browserGunzip(packed, plain.length)).resolves.toEqual(plain)
    await expect(browserGunzip(packed, plain.length - 1)).rejects.toThrow("exceeds")
    await expect(browserGunzip(Uint8Array.of(1, 2, 3, 4), 1024)).rejects.toBeDefined()
  })

  it("draws random bytes beyond the per-call limit", () => {
    const bytes = browserRandomBytes(70_000)
    expect(bytes.length).toBe(70_000)
    expect(bytes.subarray(65_536).some((byte) => byte !== 0)).toBe(true)
  })

  it("decodes base64url without Buffer", () => {
    for (const length of [0, 1, 2, 3, 31, 256]) {
      const bytes = Uint8Array.from(randomBytes(length))
      expect(decodeBase64Url(Buffer.from(bytes).toString("base64url"))).toEqual(bytes)
      expect(decodeBase64Url(Buffer.from(bytes).toString("base64"))).toEqual(bytes)
    }
  })
})

describe("cached pure AES backend", () => {
  const cached = makeCachedPureAesBackend()
  const pure = makePureAesBackend()

  it("matches the reference and native backends for IGE and streamed CTR", () => {
    for (const blocks of [1, 2, 3, 17, 64]) {
      const key = Uint8Array.from(randomBytes(32))
      const iv = Uint8Array.from(randomBytes(32))
      const plain = Uint8Array.from(randomBytes(blocks * 16))
      const encrypted = cached.igeEncrypt(plain, key, iv)
      expect(encrypted).toEqual(pure.igeEncrypt(plain, key, iv))
      expect(encrypted).toEqual(nodeAesBackend.igeEncrypt(plain, key, iv))
      expect(cached.igeDecrypt(encrypted, key, iv)).toEqual(plain)
      expect(nodeAesBackend.igeDecrypt(encrypted, key, iv)).toEqual(plain)
    }
    const key = Uint8Array.from(randomBytes(32))
    const counter = Uint8Array.from(randomBytes(16))
    counter.fill(0xff, 8) // exercise carry across the low bytes
    const streams = [cached.createCtr(key, counter), pure.createCtr(key, counter), nodeAesBackend.createCtr(key, counter)]
    for (const size of [1, 15, 16, 17, 5, 64, 3, 333]) {
      const chunk = Uint8Array.from(randomBytes(size))
      const [a, b, c] = streams.map((stream) => stream.process(chunk))
      expect(a).toEqual(b)
      expect(a).toEqual(c)
    }
  })

  it("is faster than the reference backend (records and carrier)", () => {
    const key = Uint8Array.from(randomBytes(32))
    const iv = Uint8Array.from(randomBytes(32))
    const record = Uint8Array.from(randomBytes(64 * 1024))
    const time = (run: () => void) => {
      const started = performance.now()
      run()
      return performance.now() - started
    }
    const pureMs = time(() => pure.igeDecrypt(record, key, iv))
    const cachedMs = time(() => cached.igeDecrypt(record, key, iv))
    const pureCtrMs = time(() => pure.createCtr(key, iv.subarray(0, 16)).process(record))
    const cachedCtrMs = time(() => cached.createCtr(key, iv.subarray(0, 16)).process(record))
    expect(cachedMs).toBeLessThan(pureMs)
    expect(cachedCtrMs).toBeLessThan(pureCtrMs)
  })
})
