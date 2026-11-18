/**
 * Test-only: an in-process Inline Protocol V3 server for the web transport tests.
 *
 * It runs the real server-side protocol (`InlineProtocolServerSession` from
 * `@inline-chat/protocol`, the same class `server/src/core/http/realtimeV3Host.ts`
 * drives) behind a fake browser `WebSocket`, with in-memory key and replay
 * repositories and a scripted application. No network, no database.
 */
import { constants, generateKeyPairSync, privateDecrypt, randomBytes, type KeyObject } from "node:crypto"
import { gzipSync } from "node:zlib"
import {
  InlineProtocolAuthorizationInvalidated,
  InlineProtocolServerSession,
  InlineProtocolSessionRevoked,
  MessageIdGenerator,
  RecoverableEncryptedRecordError,
  acceptObfuscatedClientHeader,
  bytesToHex,
  decodeAbridgedFrame,
  decryptRecordWithMetadata,
  encodeAbridgedPacket,
  encodeGzipPacked,
  encodeInlineUpdate,
  encodeNewSessionCreated,
  encryptRecord,
  makeRsaPublicKey,
  type EstablishedAuthorizationKey,
  type LoadedServerAuthorizationKey,
  type ObfuscatedServerHeader,
  type ServerAuthorizationKeyRepository,
} from "@inline-chat/protocol/secure"
import {
  ConnectionInit,
  Method,
  RealtimeV3Request,
  RealtimeV3Response,
  RealtimeV3Update,
  TransportPreference,
  type AuthUpgradeDeclined_Reason,
  type RpcCall,
  type RpcResult,
} from "@inline-chat/protocol/core"
import type { InlineProtocolPublicKey } from "@inline-chat/protocol/secure/connection"

/** Text the peer puts in RPC errors; it must never appear in a client error message. */
export const SERVER_ERROR_TEXT = "server-text: unauthorized"

class MemoryAuthorizationKeys implements ServerAuthorizationKeyRepository {
  readonly values = new Map<string, LoadedServerAuthorizationKey>()
  /** Permanent keys revoked server-side; a binding that proves one is answered as a confirmed revocation. */
  readonly revoked = new Map<string, Uint8Array>()

  async loadRevokedForBinding(keyId: Uint8Array): Promise<Uint8Array | undefined> {
    return this.revoked.get(bytesToHex(keyId))?.slice()
  }

  async create(key: EstablishedAuthorizationKey): Promise<"created"> {
    this.values.set(bytesToHex(key.keyId), {
      key: key.key.slice(),
      keyId: key.keyId.slice(),
      temporary: key.temporary,
      ...(key.expiresAt === undefined ? {} : { expiresAt: key.expiresAt }),
      currentServerSalt: key.serverSalt,
    })
    return "created"
  }

  async load(keyId: Uint8Array): Promise<LoadedServerAuthorizationKey | undefined> {
    const value = this.values.get(bytesToHex(keyId))
    if (!value) return undefined
    return {
      ...value,
      key: value.key.slice(),
      keyId: value.keyId.slice(),
      ...(value.binding ? { binding: { ...value.binding, permanentAuthKeyId: value.binding.permanentAuthKeyId.slice() } } : {}),
      ...(value.authorized ? { authorized: { ...value.authorized } } : {}),
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
    const value = this.values.get(bytesToHex(input.temporaryAuthKeyId))
    if (!value) throw new Error("unknown temporary key")
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

  async revoke(): Promise<boolean> {
    return true
  }
}

type RsaFixture = { publicKeys: InlineProtocolPublicKey[]; privateKey: KeyObject; profile: ReturnType<typeof makeRsaPublicKey> }
let sharedRsa: RsaFixture | undefined
const rsaFixture = (): RsaFixture => {
  if (sharedRsa) return sharedRsa
  const pair = generateKeyPairSync("rsa", { modulusLength: 2048, publicExponent: 65537 })
  const jwk = pair.publicKey.export({ format: "jwk" })
  const profile = makeRsaPublicKey(
    Uint8Array.from(Buffer.from(jwk.n!, "base64url")),
    Uint8Array.from(Buffer.from(jwk.e!, "base64url")),
  )
  sharedRsa = {
    profile,
    privateKey: pair.privateKey,
    publicKeys: [{
      modulus: Buffer.from(profile.modulus).toString("base64url"),
      exponent: Buffer.from(profile.exponent).toString("base64url"),
      fingerprint: profile.fingerprint.toString(),
    }],
  }
  return sharedRsa
}

const CONNECTING = 0
const OPEN = 1
const CLOSED = 3

type PeerConnection = {
  client: FakeWebSocket
  session: InlineProtocolServerSession
  carrier?: ObfuscatedServerHeader
  queue: Promise<void>
  /** Every packet (record) the server wrote, in order, before the carrier. */
  sent: Uint8Array[]
  /** The client's encrypted records as the server read them. */
  clientRecords: Array<{ messageId: bigint; serverSalt: bigint }>
  /** The client's session and key, learned from its first encrypted record. */
  clientSessionId?: bigint
  authKey?: Uint8Array
  authKeyId?: Uint8Array
}

export type LoopbackPeerOptions = {
  userId?: bigint
  accountSessionId?: bigint
  /** Server clock; defaults to `Date.now`. */
  now?: () => number
}

/** A fake of the browser `WebSocket` whose far end is a `LoopbackPeer`. */
class FakeWebSocket {
  static readonly CONNECTING = CONNECTING
  static readonly OPEN = OPEN
  static readonly CLOSING = 2
  static readonly CLOSED = CLOSED
  readyState = CONNECTING
  binaryType = "blob"
  bufferedAmount = 0
  onopen: ((event: unknown) => void) | null = null
  onmessage: ((event: { data: unknown }) => void) | null = null
  onclose: ((event: { code: number; reason: string }) => void) | null = null
  onerror: ((event: unknown) => void) | null = null
  closeCalls: Array<{ code?: number; reason?: string }> = []

  constructor(readonly url: string, readonly peer: LoopbackPeer) {}

  send(data: Uint8Array) {
    if (this.readyState !== OPEN) throw new Error("fake socket is not open")
    this.peer.receiveFromClient(this, Uint8Array.from(data))
  }

  close(code?: number, reason?: string) {
    if (code !== undefined && code !== 1000 && (code < 3000 || code > 4999)) {
      throw new Error(`InvalidAccessError: close code ${code} is not allowed from script`)
    }
    this.closeCalls.push({ ...(code === undefined ? {} : { code }), ...(reason === undefined ? {} : { reason }) })
    this.peer.disconnect(this, code ?? 1005, reason ?? "")
  }

  deliver(frame: Uint8Array) {
    if (this.readyState !== OPEN) return
    const data = frame.buffer.slice(frame.byteOffset, frame.byteOffset + frame.byteLength)
    queueMicrotask(() => {
      if (this.readyState === OPEN) this.onmessage?.({ data })
    })
  }

  finishClose(code: number, reason: string) {
    if (this.readyState === CLOSED) return
    this.readyState = CLOSED
    queueMicrotask(() => this.onclose?.({ code, reason }))
  }
}

export class LoopbackPeer {
  readonly keys = new MemoryAuthorizationKeys()
  readonly publicKeys: InlineProtocolPublicKey[]
  readonly connections: PeerConnection[] = []
  readonly receivedInits: ConnectionInit[] = []
  readonly receivedRpcs: RpcCall[] = []
  readonly validBearerTokens = new Set<string>()
  userId: bigint
  accountSessionId: bigint
  /** When set, sockets fail to open (a host without V3, or a blocked endpoint). */
  refuse = false
  /** When set, sockets open but the server never answers. */
  silent = false
  preference: TransportPreference | undefined
  declineUpgrade: AuthUpgradeDeclined_Reason | undefined
  rpcHandler: ((call: RpcCall) => RpcResult["result"] | undefined) | undefined
  /** When set, RPC answers wait for it (a slow application). */
  rpcGate: Promise<void> | undefined
  readonly #rsa = rsaFixture()
  readonly #now: () => number
  readonly #serverMessageIds = new MessageIdGenerator()

  constructor(options: LoopbackPeerOptions = {}) {
    this.publicKeys = this.#rsa.publicKeys
    this.userId = options.userId ?? 7n
    this.accountSessionId = options.accountSessionId ?? 11n
    this.#now = options.now ?? (() => Date.now())
    const accept = (url: string) => {
      const client = new FakeWebSocket(url, this)
      this.#accept(client)
      return client
    }
    // A constructor that returns an object hands that object to `new`.
    this.WebSocket = function FakeBrowserWebSocket(url: string) {
      return accept(url)
    } as unknown as new (url: string) => WebSocket
  }

  /** Pass as the browser runtime's `WebSocket`. */
  readonly WebSocket: new (url: string) => WebSocket

  get openConnections(): number {
    return this.connections.filter((connection) => connection.client.readyState === OPEN).length
  }

  get lastConnection(): PeerConnection | undefined {
    return this.connections.at(-1)
  }

  #accept(client: FakeWebSocket) {
    if (this.refuse) {
      queueMicrotask(() => {
        client.onerror?.({})
        client.finishClose(1006, "")
      })
      return
    }
    const session = new InlineProtocolServerSession({
      rsaKeys: [{
        ...this.#rsa.profile,
        rawDecrypt: (ciphertext) => Uint8Array.from(privateDecrypt({
          key: this.#rsa.privateKey,
          padding: constants.RSA_NO_PADDING,
        }, ciphertext)),
      }],
      authorizationKeys: this.keys,
      replay: {
        claim: async () => ({ kind: "claimed" }),
        complete: async ({ resultBody }) => ({ kind: "completed", resultBody }),
        dropAnswer: async () => "unknown",
        forgetAnswer: async () => {},
      },
      application: { dispatch: (input) => this.#dispatch(input) },
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      nowMilliseconds: () => this.#now(),
      gunzip: () => {
        throw new Error("client gzip not expected")
      },
      carrierProfile: "websocket",
      dc: 1,
    })
    this.connections.push({ client, session, queue: Promise.resolve(), sent: [], clientRecords: [] })
    queueMicrotask(() => {
      client.readyState = OPEN
      client.onopen?.({})
    })
  }

  receiveFromClient(client: FakeWebSocket, frame: Uint8Array) {
    const connection = this.connections.find((value) => value.client === client)
    if (!connection || this.silent) return
    connection.queue = connection.queue.then(async () => {
      if (!connection.carrier) {
        connection.carrier = acceptObfuscatedClientHeader(frame, 1)
        return
      }
      const decoded = decodeAbridgedFrame(connection.carrier.inbound.process(frame))
      if (decoded.kind !== "packet") return
      await this.#learnSession(connection, decoded.payload)
      const responses = await connection.session.receive(decoded.payload)
      for (const response of responses) this.#send(connection, response)
    }).catch((error: unknown) => {
      const revoked = error instanceof InlineProtocolSessionRevoked
      const invalidated = error instanceof InlineProtocolAuthorizationInvalidated
      this.closeConnection(connection, revoked || invalidated ? 4401 : 1011,
        revoked ? "session_revoked_confirmed" : "authorization_unavailable")
    })
  }

  async #learnSession(connection: PeerConnection, packet: Uint8Array) {
    const keyId = packet.subarray(0, 8)
    if (keyId.every((byte) => byte === 0)) return
    const key = await this.keys.load(keyId)
    if (!key) return
    try {
      const { fields } = decryptRecordWithMetadata(packet, key.key, {
        direction: "client-to-server",
        validServerSalts: new Set([key.currentServerSalt, ...(key.previousServerSalt === undefined ? [] : [key.previousServerSalt])]),
        nowSeconds: this.#now() / 1_000,
      })
      connection.clientSessionId = fields.sessionId
      connection.authKey = key.key
      connection.authKeyId = key.keyId
      connection.clientRecords.push({ messageId: fields.messageId, serverSalt: fields.serverSalt })
    } catch (error) {
      // The session decides what to do with a record it cannot accept; an authenticated one is still logged.
      if (error instanceof RecoverableEncryptedRecordError) {
        connection.clientRecords.push({ messageId: error.fields.messageId, serverSalt: error.fields.serverSalt })
      }
    }
  }

  #send(connection: PeerConnection, packet: Uint8Array) {
    if (!connection.carrier || connection.client.readyState !== OPEN) return
    connection.sent.push(packet)
    connection.client.deliver(connection.carrier.outbound.process(encodeAbridgedPacket(packet)))
  }

  /**
   * Writes an already-sent record again on the newest connection, as someone who
   * can see and inject into the stream would. The carrier is obfuscation only:
   * its keys travel in the client's first frame, so re-wrapping is no obstacle.
   */
  inject(packet: Uint8Array) {
    const connection = this.lastConnection
    if (!connection?.carrier || connection.client.readyState !== OPEN) throw new Error("no open connection")
    connection.client.deliver(connection.carrier.outbound.process(encodeAbridgedPacket(packet)))
  }

  /** A server message ID at `atMilliseconds` on the server clock (defaults to now). */
  serverMessageId(atMilliseconds = this.#now()): bigint {
    return this.#serverMessageIds.next(atMilliseconds, 1, 1)
  }

  /**
   * Builds a genuine server record (the server's key, the client's session) with
   * a chosen message ID and body on the newest authenticated connection, without
   * sending it. Only the server could build one; tests use it to deliver real
   * records out of order.
   */
  record(body: Uint8Array, options: { messageId?: bigint; sequenceNumber?: number; serverSalt?: bigint } = {}): Uint8Array {
    const connection = this.lastConnection
    if (!connection?.authKey || !connection.authKeyId || connection.clientSessionId === undefined) {
      throw new Error("no authenticated connection")
    }
    const key = this.keys.values.get(bytesToHex(connection.authKeyId))
    if (!key) throw new Error("unknown key")
    return encryptRecord(connection.authKey, "server-to-client", {
      serverSalt: options.serverSalt ?? key.currentServerSalt,
      sessionId: connection.clientSessionId,
      messageId: options.messageId ?? this.serverMessageId(),
      sequenceNumber: options.sequenceNumber ?? 1_001,
      body,
    }, Uint8Array.from(randomBytes(12 + ((16 - ((32 + body.length + 12) % 16)) % 16))))
  }

  /** A `new_session_created` body carrying `serverSalt`. */
  static newSessionCreated(serverSalt: bigint): Uint8Array {
    return encodeNewSessionCreated(1n, 1n, serverSalt)
  }

  /** An application update body. */
  static update(update: RealtimeV3Update): Uint8Array {
    return encodeInlineUpdate(RealtimeV3Update.toBinary(update))
  }

  /**
   * Revokes the account's permanent keys server-side, as signing the session out
   * elsewhere does: their temporary keys go too, and a later binding that proves a
   * revoked key is answered with `session_revoked_confirmed`.
   */
  revokePermanentKeys() {
    for (const [id, key] of this.keys.values) {
      if (key.temporary) continue
      this.keys.revoked.set(id, key.key.slice())
      this.keys.values.delete(id)
    }
    for (const [id, key] of this.keys.values) if (key.temporary) this.keys.values.delete(id)
  }

  async #dispatch(input: Parameters<ConstructorParameters<typeof InlineProtocolServerSession>[0]["application"]["dispatch"]>[0]) {
    const request = RealtimeV3Request.fromBinary(input.payload)
    const result = (body: RealtimeV3Response["body"]) =>
      ({ kind: "result" as const, payload: RealtimeV3Response.toBinary({ body }) })
    const unauthorized = () => result({
      oneofKind: "rpcError",
      rpcError: { reqMsgId: 0n, errorCode: 1, message: SERVER_ERROR_TEXT, code: 401, retryAfterSeconds: 0 },
    })
    input.markExecutionStarted()
    if (request.body.oneofKind === "authUpgradeSession") {
      if (!input.authorization.permanent) return unauthorized()
      if (this.declineUpgrade !== undefined) {
        return result({ oneofKind: "authUpgradeSession", authUpgradeSession: {
          state: { oneofKind: "declined", declined: { reason: this.declineUpgrade } },
        } })
      }
      const token = request.body.authUpgradeSession.bearerToken
      if (token === undefined || !this.validBearerTokens.has(token)) {
        return result({ oneofKind: "authUpgradeSession", authUpgradeSession: {
          state: { oneofKind: "notBound", notBound: {} },
        } })
      }
      const key = this.keys.values.get(bytesToHex(input.authorization.authKeyId))
      if (!key) return unauthorized()
      key.authorized = { userId: Number(this.userId), accountSessionId: Number(this.accountSessionId) }
      return result({ oneofKind: "authUpgradeSession", authUpgradeSession: {
        state: { oneofKind: "authorized", authorized: { user: { id: this.userId } as never, accountSessionId: this.accountSessionId } },
      } })
    }
    if (!input.authorization.temporaryBound) return unauthorized()
    if (request.body.oneofKind === "connectionInit") {
      this.receivedInits.push(ConnectionInit.clone(request.body.connectionInit))
      const connectionOpen = this.preference === undefined ? {} : { upgradedSessionTransport: this.preference }
      return result({ oneofKind: "connectionOpen", connectionOpen })
    }
    if (request.body.oneofKind === "rpc") {
      const call = request.body.rpc
      this.receivedRpcs.push(call)
      if (this.rpcGate) await this.rpcGate
      const custom = this.rpcHandler?.(call)
      const value: RpcResult["result"] = custom ?? (call.method === Method.GET_ME
        ? { oneofKind: "getMe", getMe: { user: { id: this.userId } as never } }
        : { oneofKind: undefined })
      return result({ oneofKind: "rpcResult", rpcResult: { reqMsgId: 0n, result: value } })
    }
    return { kind: "error" as const, code: 400, message: "unexpected request" }
  }

  /** Pushes an update on the newest connection through the session's own update path. */
  pushUpdate(update: RealtimeV3Update) {
    const connection = this.lastConnection
    if (!connection) throw new Error("no connection")
    this.#send(connection, connection.session.sendApplicationUpdate(RealtimeV3Update.toBinary(update)))
  }

  /**
   * Pushes an update wrapped in `gzip_packed`. The session only compresses
   * layer-4 results, so the record is built here with the connection's key.
   */
  pushGzippedUpdate(update: RealtimeV3Update) {
    const connection = this.lastConnection
    if (!connection) throw new Error("no connection")
    const body = encodeGzipPacked(Uint8Array.from(gzipSync(encodeInlineUpdate(RealtimeV3Update.toBinary(update)))))
    this.#send(connection, this.record(body))
  }

  /** Server-initiated close of the newest connection. */
  closeLast(code: number, reason: string) {
    const connection = this.lastConnection
    if (connection) this.closeConnection(connection, code, reason)
  }

  closeConnection(connection: PeerConnection, code: number, reason: string) {
    connection.client.finishClose(code, reason)
  }

  /** A server restart: temporary keys (held in RAM) and live sockets are gone. */
  restart() {
    for (const [id, key] of this.keys.values) if (key.temporary) this.keys.values.delete(id)
    for (const connection of this.connections) this.closeConnection(connection, 1012, "restart")
  }

  disconnect(client: FakeWebSocket, code: number, reason: string) {
    client.finishClose(code, reason)
  }
}

export { TransportPreference }

/** A virtual wall clock, monotonic clock and timer queue for the V3 runtime and the peer. */
export class VirtualTime {
  #wall: number
  #monotonic = 1_000
  #nextId = 1
  readonly #timers = new Map<number, { at: number; callback: () => void; order: number }>()

  constructor(startWallMilliseconds = Date.UTC(2026, 10, 17, 12)) {
    this.#wall = startWallMilliseconds
  }

  readonly clock = {
    wallMilliseconds: () => this.#wall,
    monotonicMilliseconds: () => this.#monotonic,
  }

  readonly timers = {
    setTimeout: (callback: () => void, delayMs: number): unknown => {
      const id = this.#nextId++
      this.#timers.set(id, { at: this.#monotonic + Math.max(0, delayMs), callback, order: id })
      return id
    },
    clearTimeout: (handle: unknown) => {
      this.#timers.delete(handle as number)
    },
  }

  now = () => this.#wall

  /** Advances both clocks, running due timers in order and letting promise chains settle between them. */
  async advance(milliseconds: number) {
    const target = this.#monotonic + milliseconds
    await settle()
    for (;;) {
      const due = [...this.#timers.entries()]
        .filter(([, timer]) => timer.at <= target)
        .sort(([, left], [, right]) => left.at - right.at || left.order - right.order)[0]
      if (!due) break
      const [id, timer] = due
      this.#timers.delete(id)
      this.#wall += timer.at - this.#monotonic
      this.#monotonic = timer.at
      timer.callback()
      await settle()
    }
    this.#wall += target - this.#monotonic
    this.#monotonic = target
    await settle()
  }
}

/** Lets queued microtasks and immediate callbacks run; not a wall-clock wait. */
export const settle = async (rounds = 5) => {
  for (let round = 0; round < rounds; round += 1) await new Promise<void>((resolve) => setImmediate(resolve))
}

/** Records a transport's events and waits for specific ones. */
export class EventRecorder<T extends { type: string }> {
  readonly events: T[] = []
  readonly #waiters: Array<{ predicate: (event: T) => boolean; from: number; resolve: (event: T) => void }> = []

  constructor(source: AsyncIterable<T>) {
    void (async () => {
      for await (const event of source) {
        this.events.push(event)
        const index = this.events.length - 1
        const matched = this.#waiters.filter((waiter) => index >= waiter.from && waiter.predicate(event))
        for (const waiter of matched) {
          this.#waiters.splice(this.#waiters.indexOf(waiter), 1)
          waiter.resolve(event)
        }
      }
    })()
  }

  /** Resolves with the first event at or after the current position matching `predicate`. */
  next(predicate: (event: T) => boolean): Promise<T> {
    return new Promise((resolve) => this.#waiters.push({ predicate, from: this.events.length, resolve }))
  }

  /** Resolves with the first matching event already recorded or still to come. */
  find(predicate: (event: T) => boolean): Promise<T> {
    const existing = this.events.find(predicate)
    if (existing) return Promise.resolve(existing)
    return this.next(predicate)
  }

  types() {
    return this.events.map((event) => event.type)
  }
}
