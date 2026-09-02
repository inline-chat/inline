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
  decodeRpcError,
  decodeRpcResult,
  decodeUnencryptedRecord,
  encodeAbridgedPacket,
  encodeBindTempAuthKey,
  encodeInlineInvoke,
  encodePing,
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
  Method,
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
const SESSION_REVOKED_CLOSE_CODE = 4401
const MAXIMUM_INBOUND_BUFFER_BYTES = 32 * 1024 * 1024
const MAXIMUM_OUTBOUND_BUFFER_BYTES = 32 * 1024 * 1024
const DEFAULT_MAX_PENDING_REQUESTS = 64
const DEFAULT_MAX_PENDING_REQUEST_BYTES = 32 * 1024 * 1024
const TEMPORARY_KEY_LIFETIME_MILLISECONDS = 86_400_000
const TEMPORARY_KEY_ROTATION_MILLISECONDS = TEMPORARY_KEY_LIFETIME_MILLISECONDS * 0.8

const readOnlyRpcMethods = new Set<Method>([
  Method.GET_ME,
  Method.GET_PEER_PHOTO,
  Method.GET_CHAT_HISTORY,
  Method.GET_SPACE_MEMBERS,
  Method.GET_CHAT_PARTICIPANTS,
  Method.GET_CHATS,
  Method.GET_USER_SETTINGS,
  Method.GET_UPDATES_STATE,
  Method.GET_CHAT,
  Method.GET_UPDATES,
  Method.SEARCH_MESSAGES,
  Method.LIST_BOTS,
  Method.REVEAL_BOT_TOKEN,
  Method.GET_MESSAGES,
  Method.GET_BOT_COMMANDS,
  Method.GET_PEER_BOT_COMMANDS,
  Method.GET_BOT_PRESENCE,
  Method.GET_SESSIONS,
  Method.CHECK_USERNAME,
  Method.GET_SPACE_URL_PREVIEW_EXCLUSIONS,
  Method.GET_USER_GROUPS,
  Method.GET_SPACE_SETTINGS,
  Method.GET_SPACE,
  Method.GET_THREAD_REFERENCES,
  Method.GET_THREAD_SUBTHREADS,
  Method.GET_PEER_BOTS,
  Method.GET_MY_BOT_CAPABILITIES,
  Method.GET_GRID,
  Method.GET_GRID_HOME,
  Method.GET_EXTERNAL_PROFILE_PHOTO,
  Method.GET_CHAT_TRANSCRIPT,
  Method.SEARCH_EXTERNAL_RESOURCES,
  Method.LIST_CONNECTORS,
  Method.SEARCH_USERS,
  Method.RESOLVE_URL_PREVIEW,
  Method.GET_BOT_AGENT,
  Method.LIST_BOT_AGENTS,
  Method.GET_CONNECTOR_CONFIG,
  Method.GET_UPLOAD_STATE,
])

/** Returns true at the exact 80% lifetime boundary using authenticated server time. */
export const temporaryAuthorizationNeedsRotation = (
  expiresAt: number,
  authenticatedServerNowMilliseconds: number,
): boolean => {
  if (!Number.isSafeInteger(expiresAt) || !Number.isFinite(authenticatedServerNowMilliseconds)) return true
  return authenticatedServerNowMilliseconds >= expiresAt * 1_000 - TEMPORARY_KEY_ROTATION_MILLISECONDS
}

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
  maxPendingRequests?: number
  maxPendingRequestBytes?: number
  random?: (length: number) => Uint8Array
  webSocketFactory?: (url: string) => WebSocket
  onUpdate?: (update: RealtimeV3Update) => void
  onClose?: (error: Error) => void
  /** Called once the authenticated clock reaches the temporary-key rotation boundary. */
  onRotationDue?: () => void | Promise<void>
}

export class InlineProtocolV3Error extends Error {
  constructor(
    readonly code: "capacity-exceeded" | "closed" | "commit-outcome-unknown" | "invalid-key" | "protocol" | "rejected-before-execution" | "rotation-due" | "timeout" | "unauthorized",
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

export class FrameInbox {
  readonly #frames: Uint8Array[] = []
  readonly #waiting: PendingFrame[] = []
  readonly #capacityBytes: number
  #failure: Error | undefined
  #queuedBytes = 0

  constructor(capacityBytes = MAXIMUM_INBOUND_BUFFER_BYTES) {
    if (!Number.isSafeInteger(capacityBytes) || capacityBytes <= 0) {
      throw new Error("Frame inbox capacity must be a positive safe integer")
    }
    this.#capacityBytes = capacityBytes
  }

  push(frame: Uint8Array): void {
    if (this.#failure) throw this.#failure
    const waiting = this.#waiting.shift()
    if (waiting) waiting.resolve(frame)
    else {
      if (this.#queuedBytes + frame.byteLength > this.#capacityBytes) {
        throw new InlineProtocolV3Error(
          "protocol",
          `Inline Protocol inbound buffer exceeded ${this.#capacityBytes} bytes`,
        )
      }
      this.#frames.push(frame)
      this.#queuedBytes += frame.byteLength
    }
  }

  fail(error: Error): void {
    if (this.#failure) return
    this.#failure = error
    this.#frames.length = 0
    this.#queuedBytes = 0
    for (const waiting of this.#waiting.splice(0)) waiting.reject(error)
  }

  async next(timeoutMs?: number): Promise<Uint8Array> {
    const frame = this.#frames.shift()
    if (frame) {
      this.#queuedBytes -= frame.byteLength
      return frame
    }
    if (this.#failure) throw this.#failure
    return await new Promise<Uint8Array>((resolve, reject) => {
      let timeout: ReturnType<typeof setTimeout> | undefined
      const pending: PendingFrame = {
        resolve: (value) => {
          if (timeout) clearTimeout(timeout)
          resolve(value)
        },
        reject: (error) => {
          if (timeout) clearTimeout(timeout)
          reject(error)
        },
      }
      if (timeoutMs !== undefined) {
        timeout = setTimeout(() => {
          const index = this.#waiting.indexOf(pending)
          if (index >= 0) this.#waiting.splice(index, 1)
          reject(new InlineProtocolV3Error("timeout", `Inline Protocol response timed out after ${timeoutMs}ms`))
        }, timeoutMs)
      }
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

type PendingContent = {
  messageId: bigint
  sequenceNumber: number
  body: Uint8Array
  resolve: (value: { messageId: bigint; result: Uint8Array }) => void
  reject: (error: Error) => void
  timeout: ReturnType<typeof setTimeout>
  removeAbortListener?: () => void
}

type PendingProbe = {
  messageId: bigint
  sequenceNumber: number
  body: Uint8Array
  resolve: () => void
  reject: (error: Error) => void
  timeout: ReturnType<typeof setTimeout>
}

export class InlineProtocolV3Connection {
  readonly #options: InlineProtocolV3ConnectionOptions
  readonly #random: (length: number) => Uint8Array
  readonly #maxPendingRequests: number
  readonly #maxPendingRequestBytes: number
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
  readonly #pendingContent = new Map<bigint, PendingContent>()
  readonly #pendingProbes = new Map<bigint, PendingProbe>()
  #pendingRequestBytes = 0
  #receiveLoop: Promise<void> | undefined
  #closing = false
  #didNotifyClose = false
  #rotationTimer: ReturnType<typeof setTimeout> | undefined
  #rotationDue = false

  private constructor(options: InlineProtocolV3ConnectionOptions) {
    this.#options = options
    this.#random = options.random ?? ((length) => Uint8Array.from(randomBytes(length)))
    this.#maxPendingRequests = options.maxPendingRequests ?? DEFAULT_MAX_PENDING_REQUESTS
    this.#maxPendingRequestBytes = options.maxPendingRequestBytes ?? DEFAULT_MAX_PENDING_REQUEST_BYTES
    if (!Number.isSafeInteger(this.#maxPendingRequests) || this.#maxPendingRequests <= 0) {
      throw new RangeError("maxPendingRequests must be a positive safe integer")
    }
    if (!Number.isSafeInteger(this.#maxPendingRequestBytes) || this.#maxPendingRequestBytes <= 0) {
      throw new RangeError("maxPendingRequestBytes must be a positive safe integer")
    }
    this.#sessionId = randomInt64(this.#random)
    this.#authorization = options.authorization ? cloneAuthorization(options.authorization) : undefined
    this.#rsaKeys = options.authorization ? [] : decodePublicKeys(options.rsaPublicKeys)
    this.#uploads = new NativeUploadClient(rpcUploadTransport(
      (method, input, signal) => this.callRpc({ method, input }, signal),
      (error) => error instanceof InlineProtocolV3Error && error.code === "commit-outcome-unknown",
    ))
  }

  static async connect(
    options: InlineProtocolV3ConnectionOptions & { temporary?: boolean },
  ): Promise<InlineProtocolV3Connection> {
    const connection = new InlineProtocolV3Connection(options)
    try {
      await connection.#open()
      if (options.authorization) {
        connection.#sampleAuthenticatedServerTime(Math.floor(Date.now() / 1_000))
      } else {
        await connection.#handshake(options.temporary ?? false)
      }
      connection.#startReceiveLoop()
      return connection
    } catch (error) {
      await connection.close().catch(() => {})
      throw error
    }
  }

  get authorization(): InlineProtocolAuthorization {
    if (!this.#authorization) throw new InlineProtocolV3Error("unauthorized", "Authorization-key handshake is incomplete")
    return cloneAuthorization(this.#authorization)
  }

  get sessionId(): bigint { return this.#sessionId }

  async close(): Promise<void> {
    this.#closing = true
    if (this.#rotationTimer) {
      clearTimeout(this.#rotationTimer)
      this.#rotationTimer = undefined
    }
    const socket = this.#socket
    this.#socket = undefined
    const closed = new InlineProtocolV3Error("closed", "Inline Protocol connection closed")
    this.#inbox.fail(closed)
    this.#failPendingContent(closed)
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
    return await this.#invoke(request)
  }

  async #invoke(
    request: RealtimeV3Request,
    onDispatched?: () => void,
    signal?: AbortSignal,
  ): Promise<RealtimeV3Response> {
    const payload = RealtimeV3Request.toBinary(request)
    const result = await this.#sendContent(encodeInlineInvoke(payload), onDispatched, signal)
    let application
    try {
      application = decodeInlineApplicationObject(result)
    } catch (error) {
      if (serviceConstructor(result) === ServiceConstructor.rpcError) {
        const rpcError = decodeRpcError(result)
        if (rpcError.code === 503) {
          throw new InlineProtocolV3Error("rejected-before-execution", rpcError.message)
        }
        if (rpcError.code === 504) {
          throw new InlineProtocolV3Error("commit-outcome-unknown", rpcError.message)
        }
      }
      throw error
    }
    if (application.kind !== "result") {
      throw new InlineProtocolV3Error("protocol", "Expected an Inline application result")
    }
    return RealtimeV3Response.fromBinary(application.payload)
  }

  async authBegin(request: AuthBeginRequest): Promise<AuthBeginResult> {
    const response = await this.invoke({ body: { oneofKind: "authBegin", authBegin: request } })
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("unauthorized", response.body.rpcError.message)
    if (response.body.oneofKind !== "authBegin") throw new InlineProtocolV3Error("protocol", "Unexpected auth.begin response")
    return response.body.authBegin
  }

  async authComplete(request: AuthCompleteRequest): Promise<AuthCompleteResult> {
    const response = await this.#invokeMutation({ body: { oneofKind: "authComplete", authComplete: request } })
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("unauthorized", response.body.rpcError.message)
    if (response.body.oneofKind !== "authComplete") throw new InlineProtocolV3Error("protocol", "Unexpected auth.complete response")
    return response.body.authComplete
  }

  async callRpc(rpc: RpcCall, signal?: AbortSignal): Promise<RpcResult["result"]> {
    const request = { body: { oneofKind: "rpc" as const, rpc } }
    const response = readOnlyRpcMethods.has(rpc.method)
      ? await this.#invoke(request, undefined, signal)
      : await this.#invokeMutation(request, signal)
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("protocol", response.body.rpcError.message)
    if (response.body.oneofKind !== "rpcResult") throw new InlineProtocolV3Error("protocol", "Unexpected RPC response")
    return response.body.rpcResult.result
  }

  /**
   * Resumes within this live connection. After reconnect, the connection owner
   * must call upload again with the same persisted clientUploadId.
   */
  async upload(input: NativeUploadInput) {
    return await this.#uploads.upload(input)
  }

  async ping(pingId = randomInt64(this.#random)): Promise<void> {
    await this.#sendPing(pingId, false)
  }

  /**
   * Authenticates a cached temporary key even when its initial clock sample is
   * already at the rotation boundary. This probe is the only post-boundary
   * admission: application RPCs remain closed while the credential owner
   * verifies whether it must replace the key.
   */
  async probeTemporaryAuthorization(pingId = randomInt64(this.#random)): Promise<void> {
    await this.#sendPing(pingId, true)
  }

  async #sendPing(pingId: bigint, allowRotationHealthProbe: boolean): Promise<void> {
    if (this.#pendingProbes.has(pingId)) {
      throw new InlineProtocolV3Error("protocol", "Duplicate Inline Protocol ping identifier")
    }
    const messageId = this.#nextClientMessageId()
    const sequenceNumber = this.#sequenceNumbers.next(false)
    const body = encodePing(pingId)
    this.#admitPending(body, allowRotationHealthProbe)
    await new Promise<void>((resolve, reject) => {
      let pending: PendingProbe
      const timeout = setTimeout(() => {
        if (this.#pendingProbes.get(pingId) !== pending) return
        this.#pendingProbes.delete(pingId)
        this.#releasePending(body)
        reject(new InlineProtocolV3Error(
          "timeout",
          `Inline Protocol response timed out after ${this.#options.requestTimeoutMs ?? REQUEST_TIMEOUT_MS}ms`,
        ))
      }, this.#options.requestTimeoutMs ?? REQUEST_TIMEOUT_MS)
      pending = { messageId, sequenceNumber, body, resolve, reject, timeout }
      this.#pendingProbes.set(pingId, pending)
      try {
        this.#sendEncrypted(messageId, sequenceNumber, body, true)
      } catch (error) {
        this.#pendingProbes.delete(pingId)
        this.#releasePending(body)
        clearTimeout(timeout)
        reject(error instanceof Error ? error : new Error(String(error)))
      }
    })
  }

  /** Checks the authenticated monotonic server clock after a successful probe. */
  temporaryAuthorizationNeedsRotation(): boolean {
    const authorization = this.#authorization
    if (!authorization?.temporary || authorization.expiresAt === undefined) return false
    return temporaryAuthorizationNeedsRotation(authorization.expiresAt, this.#clock.nowMilliseconds())
  }

  #sampleAuthenticatedServerTime(serverUnixSeconds: number): void {
    this.#clock.sample(serverUnixSeconds)
    this.#scheduleRotationTimer()
  }

  #sampleAuthenticatedServerMessage(messageId: bigint): void {
    this.#clock.sampleMessageId(messageId)
    this.#scheduleRotationTimer()
  }

  #scheduleRotationTimer(): void {
    if (this.#rotationTimer) {
      clearTimeout(this.#rotationTimer)
      this.#rotationTimer = undefined
    }
    const authorization = this.#authorization
    if (!authorization?.temporary || authorization.expiresAt === undefined || this.#closing) return
    const boundary = authorization.expiresAt * 1_000 - TEMPORARY_KEY_ROTATION_MILLISECONDS
    const delay = boundary - this.#clock.nowMilliseconds()
    if (!Number.isFinite(delay) || delay <= 0) {
      this.#markRotationDue()
      return
    }
    const timer = setTimeout(() => {
      this.#rotationTimer = undefined
      this.#scheduleRotationTimer()
    }, Math.min(delay, 2_147_000_000))
    // In Node, an idle session must not keep the host process alive solely for rotation.
    if (typeof timer !== "number" && typeof timer.unref === "function") timer.unref()
    this.#rotationTimer = timer
  }

  #markRotationDue(): void {
    if (this.#rotationDue || this.#closing) return
    this.#rotationDue = true
    void this.#options.onRotationDue?.()
  }

  async createHttpUpload(request: CreateHttpUploadRequest): Promise<CreateHttpUploadResult> {
    const response = await this.#invokeMutation({ body: { oneofKind: "createHttpUpload", createHttpUpload: request } })
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("protocol", response.body.rpcError.message)
    if (response.body.oneofKind !== "createHttpUpload") throw new InlineProtocolV3Error("protocol", "Unexpected upload response")
    return response.body.createHttpUpload
  }

  async finishHttpUpload(request: FinishHttpUploadRequest): Promise<FinishHttpUploadResult> {
    const response = await this.#invokeMutation({ body: { oneofKind: "finishHttpUpload", finishHttpUpload: request } })
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("protocol", response.body.rpcError.message)
    if (response.body.oneofKind !== "finishHttpUpload") throw new InlineProtocolV3Error("protocol", "Unexpected upload response")
    return response.body.finishHttpUpload
  }

  async #invokeMutation(request: RealtimeV3Request, signal?: AbortSignal): Promise<RealtimeV3Response> {
    let dispatched = false
    try {
      return await this.#invoke(request, () => { dispatched = true }, signal)
    } catch (error) {
      if (dispatched && error instanceof InlineProtocolV3Error &&
          ["closed", "protocol", "timeout", "unauthorized"].includes(error.code)) {
        throw new InlineProtocolV3Error(
          "commit-outcome-unknown",
          "Mutation lost its authoritative result after Inline Protocol dispatch; the outcome is unknown",
          { cause: error },
        )
      }
      throw error
    }
  }

  async bindTemporary(permanent: InlineProtocolAuthorization): Promise<void> {
    if (!this.#authorization?.temporary || this.#authorization.expiresAt === undefined || permanent.temporary) {
      throw new InlineProtocolV3Error("unauthorized", "Temporary and permanent authorization keys are required")
    }
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
  }

  async #open(): Promise<void> {
    const socket = (this.#options.webSocketFactory ?? ((url) => new WebSocket(url)))(this.#options.url)
    this.#socket = socket
    socket.binaryType = "arraybuffer"
    socket.on("message", (data) => {
      try { this.#inbox.push(rawDataBytes(data)) }
      catch (error) { this.#inbox.fail(error instanceof Error ? error : new Error(String(error))) }
    })
    socket.on("close", (code) => this.#inbox.fail(code === SESSION_REVOKED_CLOSE_CODE
      ? new InlineProtocolV3Error("unauthorized", "Inline Protocol session was revoked")
      : new InlineProtocolV3Error("closed", "Inline Protocol connection closed")))
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
      const response = decodeUnencryptedRecord(await this.#receivePacket(
        this.#options.requestTimeoutMs ?? REQUEST_TIMEOUT_MS,
      ))
      const result = handshake.receive(response.body)
      if ("request" in result) {
        request = result.request
        continue
      }
      this.#authorization = cloneAuthorization(result.established)
      this.#sampleAuthenticatedServerTime(result.serverTime)
      return
    }
  }

  async #sendContent(
    body: Uint8Array,
    onDispatched?: () => void,
    signal?: AbortSignal,
  ): Promise<Uint8Array> {
    const messageId = this.#nextClientMessageId()
    const sequenceNumber = this.#sequenceNumbers.next(true)
    return (await this.#sendPreparedContent(messageId, sequenceNumber, body, onDispatched, signal)).result
  }

  async #sendPreparedContent(
    initialMessageId: bigint,
    sequenceNumber: number,
    body: Uint8Array,
    onDispatched?: () => void,
    signal?: AbortSignal,
  ): Promise<{ messageId: bigint; result: Uint8Array }> {
    signal?.throwIfAborted()
    this.#admitPending(body)
    return await new Promise((resolve, reject) => {
      let pending: PendingContent
      const timeout = setTimeout(() => {
        if (this.#pendingContent.get(pending.messageId) !== pending) return
        this.#pendingContent.delete(pending.messageId)
        this.#releasePending(body)
        pending.removeAbortListener?.()
        reject(new InlineProtocolV3Error(
          "timeout",
          `Inline Protocol response timed out after ${this.#options.requestTimeoutMs ?? REQUEST_TIMEOUT_MS}ms`,
        ))
      }, this.#options.requestTimeoutMs ?? REQUEST_TIMEOUT_MS)
      pending = {
        messageId: initialMessageId,
        sequenceNumber,
        body,
        resolve,
        reject,
        timeout,
      }
      this.#pendingContent.set(initialMessageId, pending)
      const onAbort = () => {
        if (this.#pendingContent.get(pending.messageId) !== pending) return
        this.#pendingContent.delete(pending.messageId)
        this.#releasePending(body)
        clearTimeout(pending.timeout)
        pending.removeAbortListener?.()
        const reason = signal?.reason
        reject(reason instanceof Error ? reason : new DOMException("The operation was aborted", "AbortError"))
      }
      signal?.addEventListener("abort", onAbort, { once: true })
      pending.removeAbortListener = () => signal?.removeEventListener("abort", onAbort)
      if (signal?.aborted) onAbort()
      if (this.#pendingContent.get(initialMessageId) !== pending) return
      try {
        this.#sendEncrypted(initialMessageId, sequenceNumber, body, true)
        onDispatched?.()
      } catch (error) {
        this.#pendingContent.delete(initialMessageId)
        this.#releasePending(body)
        clearTimeout(pending.timeout)
        pending.removeAbortListener?.()
        reject(error instanceof Error ? error : new Error(String(error)))
      }
    })
  }

  #startReceiveLoop(): void {
    if (this.#receiveLoop) return
    this.#receiveLoop = this.#runReceiveLoop().catch((error: unknown) => {
      const failure = error instanceof Error ? error : new Error(String(error))
      this.#failPendingContent(failure)
      this.#inbox.fail(failure)
      this.#socket?.close(1011, "Inline Protocol receive loop failed")
      if (!this.#closing && !this.#didNotifyClose) {
        this.#didNotifyClose = true
        this.#options.onClose?.(failure)
      }
    })
  }

  async #runReceiveLoop(): Promise<void> {
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
        this.#handleBadMessage(fields.body, fields.messageId)
        continue
      }
      if (constructor === ServiceConstructor.rpcResult) {
        const result = decodeRpcResult(fields.body)
    const pending = this.#pendingContent.get(result.requestMessageId)
        if (!pending) continue
        this.#pendingContent.delete(result.requestMessageId)
        this.#releasePending(pending.body)
        clearTimeout(pending.timeout)
        pending.removeAbortListener?.()
        pending.resolve({ messageId: result.requestMessageId, result: result.result })
        continue
      }
      if (constructor === ServiceConstructor.pong) {
        if (fields.body.length !== 20) throw new InlineProtocolV3Error("protocol", "Invalid pong")
        const requestMessageId = readInt64LE(fields.body, 4)
        const pingId = readInt64LE(fields.body, 12)
        const pending = this.#pendingProbes.get(pingId)
        if (!pending) continue
        this.#pendingProbes.delete(pingId)
        this.#releasePending(pending.body)
        clearTimeout(pending.timeout)
        if (pending.messageId !== requestMessageId) {
          pending.reject(new InlineProtocolV3Error("protocol", "Pong did not match its request"))
        } else {
          pending.resolve()
        }
        continue
      }
      try {
        const application = decodeInlineApplicationObject(fields.body)
        if (application.kind === "update") {
          this.#options.onUpdate?.(RealtimeV3Update.fromBinary(application.payload))
        }
      } catch {
        // Unknown service messages are ignored only after record authentication.
      }
    }
  }

  #handleBadMessage(body: Uint8Array, serverMessageId: bigint): void {
    const bad = decodeBadMessageNotification(body)
    const pending = this.#pendingContent.get(bad.badMessageId)
    const probeEntry = [...this.#pendingProbes.entries()].find(([, value]) => value.messageId === bad.badMessageId)
    if ((!pending && !probeEntry) || bad.badSequenceNumber !== (pending ?? probeEntry![1]).sequenceNumber) {
      throw new InlineProtocolV3Error("protocol", "Server rejected an unknown outgoing message")
    }
    if (pending) this.#pendingContent.delete(bad.badMessageId)
    if (probeEntry) this.#pendingProbes.delete(probeEntry[0])
    if (bad.errorCode === 16 || bad.errorCode === 17) this.#sampleAuthenticatedServerMessage(serverMessageId)
    else if (bad.errorCode === 48 && bad.newServerSalt !== undefined) this.#setServerSalt(bad.newServerSalt)
    else {
      const rejected = pending ?? probeEntry![1]
      this.#releasePending(rejected.body)
      clearTimeout(rejected.timeout)
      if ("removeAbortListener" in rejected) rejected.removeAbortListener?.()
      rejected.reject(new InlineProtocolV3Error("protocol", `Server rejected the outgoing message (${bad.errorCode})`))
      return
    }
    const retried = pending ?? probeEntry![1]
    retried.messageId = this.#nextClientMessageId()
    if (pending) this.#pendingContent.set(retried.messageId, pending)
    else this.#pendingProbes.set(probeEntry![0], retried as PendingProbe)
    this.#sendEncrypted(retried.messageId, retried.sequenceNumber, retried.body, true)
  }

  #failPendingContent(error: Error): void {
    const pending = [...this.#pendingContent.values()]
    this.#pendingContent.clear()
    for (const item of pending) {
      clearTimeout(item.timeout)
      item.removeAbortListener?.()
      item.reject(error)
    }
    const probes = [...this.#pendingProbes.values()]
    this.#pendingProbes.clear()
    this.#pendingRequestBytes = 0
    for (const probe of probes) {
      clearTimeout(probe.timeout)
      probe.reject(error)
    }
  }

  #admitPending(body: Uint8Array, allowRotationHealthProbe = false): void {
    if (this.#rotationDue && !allowRotationHealthProbe) {
      throw new InlineProtocolV3Error(
        "rotation-due",
        "Inline Protocol temporary authorization reached its rotation boundary",
      )
    }
    const pendingCount = this.#pendingContent.size + this.#pendingProbes.size
    if (pendingCount >= this.#maxPendingRequests) {
      throw new InlineProtocolV3Error(
        "capacity-exceeded",
        `Inline Protocol pending request count capacity ${this.#maxPendingRequests} exceeded`,
      )
    }
    if (this.#pendingRequestBytes + body.byteLength > this.#maxPendingRequestBytes) {
      throw new InlineProtocolV3Error(
        "capacity-exceeded",
        `Inline Protocol pending request body-byte capacity ${this.#maxPendingRequestBytes} exceeded`,
      )
    }
    this.#pendingRequestBytes += body.byteLength
  }

  #releasePending(body: Uint8Array): void {
    this.#pendingRequestBytes -= body.byteLength
    if (this.#pendingRequestBytes < 0) {
      throw new Error("Inline Protocol pending request byte accounting underflow")
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
    this.#sampleAuthenticatedServerMessage(fields.messageId)
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

  async #receivePacket(timeoutMs?: number): Promise<Uint8Array> {
    const carrier = this.#carrier
    if (!carrier) throw new InlineProtocolV3Error("closed", "Inline Protocol carrier is unavailable")
    for (;;) {
      const wire = await this.#inbox.next(timeoutMs)
      const frame = decodeAbridgedFrame(carrier.inbound.process(wire))
      if (frame.kind === "quickAck") continue
      return frame.payload
    }
  }

  #sendRaw(bytes: Uint8Array): void {
    const socket = this.#socket
    if (!socket || socket.readyState !== WebSocket.OPEN) throw new InlineProtocolV3Error("closed", "Inline Protocol connection is not open")
    const bufferedAmount = Number.isFinite(socket.bufferedAmount) ? socket.bufferedAmount : 0
    if (bufferedAmount + bytes.byteLength > MAXIMUM_OUTBOUND_BUFFER_BYTES) {
      throw new InlineProtocolV3Error(
        "closed",
        `Inline Protocol outbound buffer exceeded ${MAXIMUM_OUTBOUND_BUFFER_BYTES} bytes`,
      )
    }
    socket.send(bytes)
  }
}
