import { randomBytes } from "node:crypto"
import { WebSocket } from "ws"
import {
  AuthenticatedServerClock,
  InlineHandshakeClient,
  MessageIdGenerator,
  SequenceNumberGenerator,
  ServiceConstructor,
  createObfuscatedClientHeader,
  createTemporaryKeyBindingProof,
  decodeAbridgedFrame,
  decodeBadMessageNotification,
  decodeInlineApplicationObject,
  decodeMsgsAck,
  decodeRpcResult,
  decodeUnencryptedRecord,
  encodeAbridgedPacket,
  encodeBindTempAuthKey,
  encodeInlineInvoke,
  encodeMsgsAck,
  encodeUnencryptedRecord,
  encryptRecord,
  decryptRecord,
  isValidObfuscatedHeader,
  makeRsaPublicKey,
  readInt64LE,
  serviceConstructor,
  type EstablishedAuthorizationKey,
  type HandshakeRsaPublicKey,
  type ObfuscatedClientHeader,
} from "@inline-chat/protocol/secure"
import {
  NativeUploadClient,
  rpcUploadTransport,
  type NativeUploadInput,
} from "@inline-chat/protocol/uploads"
import {
  RealtimeV3Request,
  RealtimeV3Response,
  RealtimeV3Update,
  type AuthBeginRequest,
  type AuthBeginResult,
  type AuthCompleteRequest,
  type AuthCompleteResult,
  type CreateHttpUploadRequest,
  type CreateHttpUploadResult,
  type FinishHttpUploadRequest,
  type FinishHttpUploadResult,
  type RpcCall,
  type RpcResult,
} from "@inline-chat/protocol/core"

const BOOL_TRUE = 0x997275b5
const CONNECT_TIMEOUT_MS = 30_000
const REQUEST_TIMEOUT_MS = 60_000

export type InlineProtocolPublicKey = {
  modulus: string
  exponent: string
  fingerprint: string
}

export type InlineProtocolAuthorization = {
  key: Uint8Array
  keyId: Uint8Array
  serverSalt: bigint
  temporary: boolean
  expiresAt?: number
}

export type InlineProtocolV3ConnectionOptions = {
  url: string
  rsaPublicKeys: readonly InlineProtocolPublicKey[]
  authorization?: InlineProtocolAuthorization
  connectTimeoutMs?: number
  requestTimeoutMs?: number
  random?: (length: number) => Uint8Array
  webSocketFactory?: (url: string) => WebSocket
  onUpdate?: (update: RealtimeV3Update) => void
}

export class InlineProtocolV3Error extends Error {
  constructor(
    readonly code: "closed" | "invalid-key" | "protocol" | "timeout" | "unauthorized",
    message: string,
    options?: ErrorOptions,
  ) {
    super(message, options)
    this.name = `InlineProtocolV3Error:${code}`
  }
}

type PendingFrame = {
  resolve: (frame: Uint8Array) => void
  reject: (error: Error) => void
}

class FrameInbox {
  readonly #frames: Uint8Array[] = []
  readonly #waiting: PendingFrame[] = []
  #failure: Error | undefined

  push(frame: Uint8Array): void {
    const waiting = this.#waiting.shift()
    if (waiting) waiting.resolve(frame)
    else this.#frames.push(frame)
  }

  fail(error: Error): void {
    this.#failure = error
    for (const waiting of this.#waiting.splice(0)) waiting.reject(error)
  }

  async next(timeoutMs: number): Promise<Uint8Array> {
    const frame = this.#frames.shift()
    if (frame) return frame
    if (this.#failure) throw this.#failure
    return await new Promise<Uint8Array>((resolve, reject) => {
      const pending: PendingFrame = {
        resolve: (value) => {
          clearTimeout(timeout)
          resolve(value)
        },
        reject: (error) => {
          clearTimeout(timeout)
          reject(error)
        },
      }
      const timeout = setTimeout(() => {
        const index = this.#waiting.indexOf(pending)
        if (index >= 0) this.#waiting.splice(index, 1)
        reject(new InlineProtocolV3Error("timeout", `Inline Protocol response timed out after ${timeoutMs}ms`))
      }, timeoutMs)
      this.#waiting.push(pending)
    })
  }
}

const rawDataBytes = (data: WebSocket.RawData): Uint8Array => {
  if (data instanceof ArrayBuffer) return new Uint8Array(data)
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice()
  if (Array.isArray(data)) return Uint8Array.from(Buffer.concat(data))
  throw new InlineProtocolV3Error("protocol", "Unsupported WebSocket frame type")
}

const randomInt64 = (random: (length: number) => Uint8Array): bigint => {
  const bytes = random(8)
  if (bytes.length !== 8) throw new InlineProtocolV3Error("protocol", "CSPRNG returned an invalid value")
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getBigInt64(0, true)
}

const randomLowBits = (random: (length: number) => Uint8Array): number => {
  const bytes = random(4)
  if (bytes.length !== 4) throw new InlineProtocolV3Error("protocol", "CSPRNG returned an invalid value")
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(0, true) & 0x3fffffff
}

const recordPadding = (bodyLength: number, random: (length: number) => Uint8Array): Uint8Array => {
  const length = 12 + ((16 - ((32 + bodyLength + 12) % 16)) % 16)
  const padding = random(length)
  if (padding.length !== length) throw new InlineProtocolV3Error("protocol", "CSPRNG returned invalid padding")
  return padding
}

const decodePublicKeys = (keys: readonly InlineProtocolPublicKey[]): HandshakeRsaPublicKey[] => {
  if (keys.length === 0) throw new InlineProtocolV3Error("invalid-key", "At least one pinned RSA key is required")
  return keys.map((value) => {
    const profile = makeRsaPublicKey(
      Uint8Array.from(Buffer.from(value.modulus, "base64url")),
      Uint8Array.from(Buffer.from(value.exponent, "base64url")),
    )
    if (profile.fingerprint.toString() !== value.fingerprint) {
      throw new InlineProtocolV3Error("invalid-key", "Pinned RSA key fingerprint does not match its key material")
    }
    return profile
  })
}

const cloneAuthorization = (value: EstablishedAuthorizationKey | InlineProtocolAuthorization): InlineProtocolAuthorization => ({
  key: value.key.slice(),
  keyId: value.keyId.slice(),
  serverSalt: value.serverSalt,
  temporary: value.temporary,
  ...(value.expiresAt === undefined ? {} : { expiresAt: value.expiresAt }),
})

export class InlineProtocolV3Connection {
  readonly #options: InlineProtocolV3ConnectionOptions
  readonly #random: (length: number) => Uint8Array
  readonly #inbox = new FrameInbox()
  readonly #messageIds = new MessageIdGenerator()
  readonly #sequenceNumbers = new SequenceNumberGenerator()
  readonly #clock = new AuthenticatedServerClock({
    nowMilliseconds: () => performance.now(),
  })
  readonly #sessionId: bigint
  readonly #rsaKeys: HandshakeRsaPublicKey[]
  readonly #uploads: NativeUploadClient
  #socket: WebSocket | undefined
  #carrier: ObfuscatedClientHeader | undefined
  #authorization: InlineProtocolAuthorization | undefined
  #requestQueue = Promise.resolve()

  private constructor(options: InlineProtocolV3ConnectionOptions) {
    this.#options = options
    this.#random = options.random ?? ((length) => Uint8Array.from(randomBytes(length)))
    this.#sessionId = randomInt64(this.#random)
    this.#authorization = options.authorization ? cloneAuthorization(options.authorization) : undefined
    this.#rsaKeys = options.authorization ? [] : decodePublicKeys(options.rsaPublicKeys)
    this.#uploads = new NativeUploadClient(rpcUploadTransport(
      (method, input) => this.callRpc({ method, input }),
    ))
  }

  static async connect(
    options: InlineProtocolV3ConnectionOptions & { temporary?: boolean },
  ): Promise<InlineProtocolV3Connection> {
    const connection = new InlineProtocolV3Connection(options)
    await connection.#open()
    if (options.authorization) {
      connection.#clock.sample(Math.floor(Date.now() / 1_000))
    } else {
      await connection.#handshake(options.temporary ?? false)
    }
    return connection
  }

  get authorization(): InlineProtocolAuthorization {
    if (!this.#authorization) throw new InlineProtocolV3Error("unauthorized", "Authorization-key handshake is incomplete")
    return cloneAuthorization(this.#authorization)
  }

  get sessionId(): bigint { return this.#sessionId }

  async close(): Promise<void> {
    const socket = this.#socket
    this.#socket = undefined
    if (!socket || socket.readyState === WebSocket.CLOSED) return
    await new Promise<void>((resolve) => {
      const timeout = setTimeout(resolve, 1_000)
      socket.once("close", () => {
        clearTimeout(timeout)
        resolve()
      })
      socket.close(1000, "Client closing")
    })
  }

  async invoke(request: RealtimeV3Request): Promise<RealtimeV3Response> {
    return await this.#serialized(async () => {
      const payload = RealtimeV3Request.toBinary(request)
      const result = await this.#sendContent(encodeInlineInvoke(payload))
      const application = decodeInlineApplicationObject(result)
      if (application.kind !== "result") {
        throw new InlineProtocolV3Error("protocol", "Expected an Inline application result")
      }
      return RealtimeV3Response.fromBinary(application.payload)
    })
  }

  async authBegin(request: AuthBeginRequest): Promise<AuthBeginResult> {
    const response = await this.invoke({ body: { oneofKind: "authBegin", authBegin: request } })
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("unauthorized", response.body.rpcError.message)
    if (response.body.oneofKind !== "authBegin") throw new InlineProtocolV3Error("protocol", "Unexpected auth.begin response")
    return response.body.authBegin
  }

  async authComplete(request: AuthCompleteRequest): Promise<AuthCompleteResult> {
    const response = await this.invoke({ body: { oneofKind: "authComplete", authComplete: request } })
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("unauthorized", response.body.rpcError.message)
    if (response.body.oneofKind !== "authComplete") throw new InlineProtocolV3Error("protocol", "Unexpected auth.complete response")
    return response.body.authComplete
  }

  async callRpc(rpc: RpcCall): Promise<RpcResult["result"]> {
    const response = await this.invoke({ body: { oneofKind: "rpc", rpc } })
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("protocol", response.body.rpcError.message)
    if (response.body.oneofKind !== "rpcResult") throw new InlineProtocolV3Error("protocol", "Unexpected RPC response")
    return response.body.rpcResult.result
  }

  async upload(input: NativeUploadInput) {
    return await this.#uploads.upload(input)
  }

  async createHttpUpload(request: CreateHttpUploadRequest): Promise<CreateHttpUploadResult> {
    const response = await this.invoke({ body: { oneofKind: "createHttpUpload", createHttpUpload: request } })
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("protocol", response.body.rpcError.message)
    if (response.body.oneofKind !== "createHttpUpload") throw new InlineProtocolV3Error("protocol", "Unexpected upload response")
    return response.body.createHttpUpload
  }

  async finishHttpUpload(request: FinishHttpUploadRequest): Promise<FinishHttpUploadResult> {
    const response = await this.invoke({ body: { oneofKind: "finishHttpUpload", finishHttpUpload: request } })
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("protocol", response.body.rpcError.message)
    if (response.body.oneofKind !== "finishHttpUpload") throw new InlineProtocolV3Error("protocol", "Unexpected upload response")
    return response.body.finishHttpUpload
  }

  async bindTemporary(permanent: InlineProtocolAuthorization): Promise<void> {
    if (!this.#authorization?.temporary || this.#authorization.expiresAt === undefined || permanent.temporary) {
      throw new InlineProtocolV3Error("unauthorized", "Temporary and permanent authorization keys are required")
    }
    await this.#serialized(async () => {
      let messageId = this.#nextClientMessageId()
      const sequenceNumber = this.#sequenceNumbers.next(true)
      const nonce = randomInt64(this.#random)
      const body = encodeBindTempAuthKey({
        permanentAuthKeyId: new DataView(permanent.keyId.buffer, permanent.keyId.byteOffset, 8).getBigInt64(0, true),
        nonce,
        expiresAt: this.#authorization!.expiresAt!,
        encryptedMessage: createTemporaryKeyBindingProof({
          permanentAuthKey: permanent.key,
          temporaryAuthKey: this.#authorization!.key,
          temporarySessionId: this.#sessionId,
          messageId,
          nonce,
          expiresAt: this.#authorization!.expiresAt!,
          randomInt128: this.#random(16),
          randomPadding: this.#random(8),
        }),
      })
      let result: Uint8Array
      ({ messageId, result } = await this.#sendPreparedContent(messageId, sequenceNumber, body))
      if (result.length !== 4 || new DataView(result.buffer, result.byteOffset, 4).getUint32(0, true) !== BOOL_TRUE) {
        throw new InlineProtocolV3Error("protocol", "Server rejected temporary authorization-key binding")
      }
    })
  }

  async #open(): Promise<void> {
    const socket = (this.#options.webSocketFactory ?? ((url) => new WebSocket(url)))(this.#options.url)
    this.#socket = socket
    socket.binaryType = "arraybuffer"
    socket.on("message", (data) => {
      try { this.#inbox.push(rawDataBytes(data)) }
      catch (error) { this.#inbox.fail(error instanceof Error ? error : new Error(String(error))) }
    })
    socket.on("close", () => this.#inbox.fail(new InlineProtocolV3Error("closed", "Inline Protocol connection closed")))
    socket.on("error", (error) => this.#inbox.fail(new InlineProtocolV3Error("closed", "Inline Protocol WebSocket failed", { cause: error })))
    await new Promise<void>((resolve, reject) => {
      if (socket.readyState === WebSocket.OPEN) return resolve()
      const timeout = setTimeout(() => reject(new InlineProtocolV3Error("timeout", "Inline Protocol connection timed out")), this.#options.connectTimeoutMs ?? CONNECT_TIMEOUT_MS)
      socket.once("open", () => {
        clearTimeout(timeout)
        resolve()
      })
      socket.once("error", (error) => {
        clearTimeout(timeout)
        reject(new InlineProtocolV3Error("closed", "Inline Protocol WebSocket failed", { cause: error }))
      })
    })
    let header: Uint8Array
    do header = this.#random(64)
    while (!isValidObfuscatedHeader(header))
    this.#carrier = createObfuscatedClientHeader(header, 1)
    this.#sendRaw(this.#carrier.wireHeader)
  }

  async #handshake(temporary: boolean): Promise<void> {
    const handshake = new InlineHandshakeClient({
      rsaKeys: this.#rsaKeys,
      randomBytes: this.#random,
      dc: 1,
    })
    let request = handshake.begin(temporary)
    for (;;) {
      const messageId = this.#messageIds.next(Date.now(), randomLowBits(this.#random), 0)
      this.#sendPacket(encodeUnencryptedRecord(messageId, request))
      const response = decodeUnencryptedRecord(await this.#receivePacket())
      const result = handshake.receive(response.body)
      if ("request" in result) {
        request = result.request
        continue
      }
      this.#authorization = cloneAuthorization(result.established)
      this.#clock.sample(result.serverTime)
      return
    }
  }

  async #sendContent(body: Uint8Array): Promise<Uint8Array> {
    const messageId = this.#nextClientMessageId()
    const sequenceNumber = this.#sequenceNumbers.next(true)
    return (await this.#sendPreparedContent(messageId, sequenceNumber, body)).result
  }

  async #sendPreparedContent(
    initialMessageId: bigint,
    sequenceNumber: number,
    body: Uint8Array,
  ): Promise<{ messageId: bigint; result: Uint8Array }> {
    let messageId = initialMessageId
    this.#sendEncrypted(messageId, sequenceNumber, body, true)
    for (;;) {
      const fields = await this.#receiveEncrypted()
      if (fields.sequenceNumber % 2 === 1) await this.#sendAcknowledgements([fields.messageId])
      const constructor = serviceConstructor(fields.body)
      if (constructor === ServiceConstructor.newSessionCreated) {
        this.#setServerSalt(readInt64LE(fields.body, 20))
        continue
      }
      if (constructor === ServiceConstructor.msgsAck) {
        decodeMsgsAck(fields.body)
        continue
      }
      if (constructor === ServiceConstructor.badMsgNotification || constructor === ServiceConstructor.badServerSalt) {
        const bad = decodeBadMessageNotification(fields.body)
        if (bad.badMessageId !== messageId || bad.badSequenceNumber !== sequenceNumber) {
          throw new InlineProtocolV3Error("protocol", "Server rejected an unknown outgoing message")
        }
        if (bad.errorCode === 16 || bad.errorCode === 17) this.#clock.sampleMessageId(fields.messageId)
        else if (bad.errorCode === 48 && bad.newServerSalt !== undefined) this.#setServerSalt(bad.newServerSalt)
        else throw new InlineProtocolV3Error("protocol", `Server rejected the outgoing message (${bad.errorCode})`)
        messageId = this.#nextClientMessageId()
        this.#sendEncrypted(messageId, sequenceNumber, body, true)
        continue
      }
      if (constructor === ServiceConstructor.rpcResult) {
        const result = decodeRpcResult(fields.body)
        if (result.requestMessageId === messageId) return { messageId, result: result.result }
        continue
      }
      try {
        const application = decodeInlineApplicationObject(fields.body)
        if (application.kind === "update") this.#options.onUpdate?.(RealtimeV3Update.fromBinary(application.payload))
      } catch {
        // Unknown service messages are ignored only after record authentication.
      }
    }
  }

  async #receiveEncrypted() {
    const authorization = this.#authorization
    if (!authorization) throw new InlineProtocolV3Error("unauthorized", "Authorization-key handshake is incomplete")
    const packet = await this.#receivePacket()
    const fields = decryptRecord(packet, authorization.key, {
      direction: "server-to-client",
      sessionId: this.#sessionId,
      validServerSalts: new Set([authorization.serverSalt]),
      nowSeconds: this.#clock.nowMilliseconds() / 1_000,
    })
    this.#clock.sampleMessageId(fields.messageId)
    return fields
  }

  async #sendAcknowledgements(messageIds: readonly bigint[]): Promise<void> {
    const body = encodeMsgsAck(messageIds)
    this.#sendEncrypted(this.#nextClientMessageId(), this.#sequenceNumbers.next(false), body, false)
  }

  #sendEncrypted(messageId: bigint, sequenceNumber: number, body: Uint8Array, quickAck: boolean): void {
    const authorization = this.#authorization
    if (!authorization) throw new InlineProtocolV3Error("unauthorized", "Authorization-key handshake is incomplete")
    const record = encryptRecord(authorization.key, "client-to-server", {
      serverSalt: authorization.serverSalt,
      sessionId: this.#sessionId,
      messageId,
      sequenceNumber,
      body,
    }, recordPadding(body.length, this.#random))
    this.#sendPacket(record, quickAck)
  }

  #nextClientMessageId(): bigint {
    return this.#messageIds.next(this.#clock.nowMilliseconds(), randomLowBits(this.#random), 0)
  }

  #setServerSalt(serverSalt: bigint): void {
    if (!this.#authorization) throw new InlineProtocolV3Error("unauthorized", "Authorization-key handshake is incomplete")
    this.#authorization.serverSalt = serverSalt
  }

  #sendPacket(packet: Uint8Array, quickAck = false): void {
    const carrier = this.#carrier
    if (!carrier) throw new InlineProtocolV3Error("closed", "Inline Protocol carrier is unavailable")
    this.#sendRaw(carrier.outbound.process(encodeAbridgedPacket(packet, quickAck)))
  }

  async #receivePacket(): Promise<Uint8Array> {
    const carrier = this.#carrier
    if (!carrier) throw new InlineProtocolV3Error("closed", "Inline Protocol carrier is unavailable")
    for (;;) {
      const wire = await this.#inbox.next(this.#options.requestTimeoutMs ?? REQUEST_TIMEOUT_MS)
      const frame = decodeAbridgedFrame(carrier.inbound.process(wire))
      if (frame.kind === "quickAck") continue
      return frame.payload
    }
  }

  #sendRaw(bytes: Uint8Array): void {
    const socket = this.#socket
    if (!socket || socket.readyState !== WebSocket.OPEN) throw new InlineProtocolV3Error("closed", "Inline Protocol connection is not open")
    socket.send(bytes)
  }

  async #serialized<T>(operation: () => Promise<T>): Promise<T> {
    const previous = this.#requestQueue
    let release: () => void = () => {}
    this.#requestQueue = new Promise<void>((resolve) => { release = resolve })
    await previous
    try { return await operation() }
    finally { release() }
  }
}
