/**
 * Runtime-neutral Inline Protocol V3 client connection.
 *
 * A port of `packages/sdk/src/realtime/v3-connection.ts` with every host
 * dependency injected through `InlineProtocolRuntime` (socket, CSPRNG, gunzip,
 * AES backend, timers, clock). Handshake, temporary-key binding and rotation,
 * acknowledgements, containers and bad-message recovery behave as in the SDK.
 * This module imports nothing from Node and nothing from the DOM.
 *
 * Where it is stricter than the SDK (security review, 2026-11-17):
 * - Receive window: every server message ID is claimed in a `ReceiveMessageWindow`
 *   (1,000 IDs, as on the server). A repeated ID or one below the window is
 *   dropped unprocessed and unacknowledged; reordering inside the window is fine.
 * - The authenticated clock is sampled only from a new highest server message ID,
 *   and `new_session_created` changes the salt only from a newer record, so a
 *   held-back record cannot rewind the clock or restore an old salt.
 * - A cached key's clock starts as the device's estimate: records are not
 *   time-checked and rotation is not scheduled until an authenticated record
 *   arrives, and the server's time corrections (16, 17, and 20 before that first
 *   record) are followed, so a skewed device clock can still connect.
 * - The salt of server records is not checked (it is the server's current salt);
 *   `bad_server_salt` is accepted and followed.
 * - The unauthenticated `res_pq` challenge is bounded before the shared
 *   handshake factors it (`requireBoundedPqChallenge`).
 * - Errors leaving this module are `InlineProtocolV3Error`s with fixed text and
 *   numeric codes: no decrypted field, server text or key material.
 * - A 4401 close is classified (`session-revoked` for `session_revoked_confirmed`,
 *   else `authorization-invalidated`), but the close frame is not authenticated;
 *   callers must not erase credentials or data on it alone.
 */
import { setAesBackend, getAesBackend } from "./aesBackend.js"
import { decodeInlineApplicationObject, encodeInlineInvoke, INLINE_INVOKE_CONSTRUCTOR, INLINE_REALTIME_LAYER } from "./application.js"
import { createTemporaryKeyBindingProof, encodeBindTempAuthKey } from "./binding.js"
import { readInt64LE } from "./bytes.js"
import {
  createObfuscatedClientHeader,
  decodeAbridgedFrame,
  encodeAbridgedPacket,
  isValidObfuscatedHeader,
  type ObfuscatedClientHeader,
} from "./carrier.js"
import { decodeResPq, decodeUnencryptedRecord, encodeUnencryptedRecord } from "./handshakeSchema.js"
import {
  InlineHandshakeClient,
  makeRsaPublicKey,
  type EstablishedAuthorizationKey,
  type HandshakeRsaPublicKey,
} from "./handshakeState.js"
import { RecoverableEncryptedRecordError, decryptRecord, encryptRecord, type EncryptedRecordFields } from "./record.js"
import {
  ServiceConstructor,
  decodeBadMessageNotification,
  decodeGzipPacked,
  decodeMsgsAck,
  decodeRpcError,
  decodeRpcResult,
  encodeMessageContainer,
  encodeMsgsAck,
  encodePing,
  serviceConstructor,
} from "./service.js"
import { AuthenticatedServerClock, MessageIdGenerator, ReceiveMessageWindow, SequenceNumberGenerator } from "./session.js"
import {
  InlineProtocolSocketState,
  decodeBase64Url,
  globalInlineProtocolClock,
  globalInlineProtocolTimers,
  type InlineProtocolClock,
  type InlineProtocolGunzip,
  type InlineProtocolRuntime,
  type InlineProtocolSocket,
  type InlineProtocolTimerHandle,
  type InlineProtocolTimers,
} from "./connectionRuntime.js"
import { normalizeRpcInput, type RpcInput } from "./connectionRpcInput.js"
import { NativeUploadClient, rpcUploadTransport, type NativeUploadInput } from "../uploads.js"
import { READ_ONLY_RPC_METHODS } from "../transfers.js"
import {
  Method,
  RealtimeV3Request,
  RealtimeV3Response,
  RealtimeV3Update,
  type AuthBeginRequest,
  type AuthBeginResult,
  type AuthCompleteRequest,
  type AuthCompleteResult,
  type AuthUpgradeSessionResult,
  type CreateHttpUploadRequest,
  type CreateHttpUploadResult,
  type FinishHttpUploadRequest,
  type FinishHttpUploadResult,
  type RpcCall,
  type RpcResult,
} from "../core.js"

export * from "./connectionRuntime.js"
export * from "./connectionRpcInput.js"
export { makeCachedPureAesBackend } from "./aesCached.js"
export { makePureAesBackend } from "./aesPure.js"
export type { AesBackend, AesCtrState } from "./aesBackend.js"

const BOOL_TRUE = 0x997275b5
const CONNECT_TIMEOUT_MS = 30_000
const REQUEST_TIMEOUT_MS = 60_000
const CLOSE_WAIT_MS = 1_000
export const INLINE_PROTOCOL_SESSION_REVOKED_CLOSE_CODE = 4401
export const INLINE_PROTOCOL_SESSION_REVOKED_CLOSE_REASON = "session_revoked_confirmed"
const MAXIMUM_INBOUND_BUFFER_BYTES = 32 * 1024 * 1024
const MAXIMUM_OUTBOUND_BUFFER_BYTES = 32 * 1024 * 1024
const DEFAULT_MAX_PENDING_REQUESTS = 64
const DEFAULT_MAX_PENDING_REQUEST_BYTES = 32 * 1024 * 1024
const TEMPORARY_KEY_LIFETIME_MILLISECONDS = 86_400_000
export const TEMPORARY_KEY_ROTATION_MILLISECONDS = TEMPORARY_KEY_LIFETIME_MILLISECONDS * 0.8
// Acknowledgements ride along with the next request; a quiet connection flushes
// them on its own after this delay or once this many are pending.
const ACK_FLUSH_DELAY_MS = 30_000
const ACK_FLUSH_PENDING = 16
const MAXIMUM_GZIP_OUTPUT_BYTES = 16 * 1024 * 1024
const MAXIMUM_TIMER_DELAY_MS = 2_147_000_000
/** Server message IDs remembered per connection; older or repeated IDs are dropped. Matches the server's window. */
const RECEIVE_WINDOW_MESSAGES = 1_000
/**
 * Pollard-Brent steps the client spends on the unauthenticated `pq` before giving
 * up. The server's challenge (two ~31-bit primes) takes about 2^15 on average and
 * never ran out of 2^17 in 20,000 trials; a prime chosen by someone on the wire is
 * refused after about 50 ms (Apple silicon) instead of blocking the thread for the
 * shared factoring's ~15 s.
 */
const PQ_FACTOR_STEP_BUDGET = 1 << 19

const readOnlyRpcMethods = READ_ONLY_RPC_METHODS

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
  runtime: InlineProtocolRuntime
  rsaPublicKeys: readonly InlineProtocolPublicKey[]
  authorization?: InlineProtocolAuthorization
  connectTimeoutMs?: number
  requestTimeoutMs?: number
  maxPendingRequests?: number
  maxPendingRequestBytes?: number
  onUpdate?: (update: RealtimeV3Update) => void
  onClose?: (error: Error) => void
  /** Called once the authenticated clock reaches the temporary-key rotation boundary. */
  onRotationDue?: () => void | Promise<void>
}

export type InlineProtocolV3ErrorCode =
  | "authorization-invalidated"
  | "session-revoked"
  | "capacity-exceeded"
  | "closed"
  | "commit-outcome-unknown"
  | "invalid-key"
  | "protocol"
  | "rejected-before-execution"
  | "rotation-due"
  | "timeout"
  | "unauthorized"

export class InlineProtocolV3Error extends Error {
  constructor(
    readonly code: InlineProtocolV3ErrorCode,
    message: string,
    options?: ErrorOptions,
  ) {
    super(message, options)
    this.name = `InlineProtocolV3Error:${code}`
  }
}

export type InlineProtocolInvokeOptions = {
  signal?: AbortSignal
  /** Called synchronously once the request record has been handed to the socket. */
  onDispatched?: () => void
}

type PendingFrame = {
  resolve: (frame: Uint8Array) => void
  reject: (error: Error) => void
}

export class FrameInbox {
  readonly #frames: Uint8Array[] = []
  readonly #waiting: PendingFrame[] = []
  readonly #capacityBytes: number
  readonly #timers: InlineProtocolTimers
  #failure: Error | undefined
  #queuedBytes = 0

  constructor(capacityBytes = MAXIMUM_INBOUND_BUFFER_BYTES, timers: InlineProtocolTimers = globalInlineProtocolTimers()) {
    if (!Number.isSafeInteger(capacityBytes) || capacityBytes <= 0) {
      throw new Error("Frame inbox capacity must be a positive safe integer")
    }
    this.#capacityBytes = capacityBytes
    this.#timers = timers
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
      let timeout: InlineProtocolTimerHandle | undefined
      const pending: PendingFrame = {
        resolve: (value) => {
          if (timeout !== undefined) this.#timers.clearTimeout(timeout)
          resolve(value)
        },
        reject: (error) => {
          if (timeout !== undefined) this.#timers.clearTimeout(timeout)
          reject(error)
        },
      }
      if (timeoutMs !== undefined) {
        timeout = this.#timers.setTimeout(() => {
          const index = this.#waiting.indexOf(pending)
          if (index >= 0) this.#waiting.splice(index, 1)
          reject(new InlineProtocolV3Error("timeout", `Inline Protocol response timed out after ${timeoutMs}ms`))
        }, timeoutMs)
      }
      this.#waiting.push(pending)
    })
  }
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

const absolute = (value: bigint): bigint => value < 0n ? -value : value

const greatestCommonDivisor = (left: bigint, right: bigint): bigint => {
  let a = absolute(left)
  let b = absolute(right)
  while (b !== 0n) [a, b] = [b, a % b]
  return a
}

const randomBelow = (bound: bigint, random: (length: number) => Uint8Array): bigint => {
  const bytes = random(8)
  if (bytes.length !== 8) throw new InlineProtocolV3Error("protocol", "CSPRNG returned an invalid value")
  return new DataView(bytes.buffer, bytes.byteOffset, 8).getBigUint64(0, false) % bound
}

/** Pollard-Brent with batched gcds; true once a nontrivial factor of `n` turns up within `budget` steps. */
const hasFactorWithin = (n: bigint, budget: number, random: (length: number) => Uint8Array): boolean => {
  const batch = 64
  let spent = 0
  while (spent < budget) {
    const c = randomBelow(n - 1n, random) + 1n
    const step = (value: bigint) => (value * value + c) % n
    let y = randomBelow(n, random)
    let x = y
    let saved = y
    let product = 1n
    let divisor = 1n
    for (let length = 1; divisor === 1n && spent < budget; length *= 2) {
      x = y
      for (let index = 0; index < length; index += 1) y = step(y)
      spent += length
      for (let done = 0; done < length && divisor === 1n; done += batch) {
        saved = y
        const steps = Math.min(batch, length - done)
        for (let index = 0; index < steps; index += 1) {
          y = step(y)
          product = (product * absolute(x - y)) % n
        }
        spent += steps
        divisor = greatestCommonDivisor(product, n)
      }
    }
    if (divisor === n) {
      // The batch overshot; walk it again one step at a time (at most `batch` steps).
      divisor = 1n
      for (let index = 0; index < batch && divisor === 1n; index += 1) {
        saved = step(saved)
        divisor = greatestCommonDivisor(x - saved, n)
      }
    }
    if (divisor > 1n && divisor < n) return true
  }
  return false
}

/**
 * Bounds the client's work on `res_pq` before the shared handshake factors it.
 * Nothing in that message is authenticated, so its `pq` must be one that the
 * handshake can factor quickly: 1 to 8 bytes, below 2^63, with a factor found
 * within `PQ_FACTOR_STEP_BUDGET` steps. Anything else fails the handshake.
 */
const requireBoundedPqChallenge = (body: Uint8Array, random: (length: number) => Uint8Array): void => {
  let pq: Uint8Array
  try {
    pq = decodeResPq(body).pq
  } catch {
    return // Not a res_pq; the handshake rejects it itself.
  }
  const invalid = () => new InlineProtocolV3Error("protocol", "Inline Protocol pq challenge is outside the client's bound")
  if (pq.length === 0 || pq.length > 8) throw invalid()
  let value = 0n
  for (const byte of pq) value = (value << 8n) | BigInt(byte)
  if (value <= 3n || value >= (1n << 63n)) throw invalid()
  if ((value & 1n) === 0n) return
  if (!hasFactorWithin(value, PQ_FACTOR_STEP_BUDGET, random)) throw invalid()
}

/** Server error text is decrypted content; errors carry only its numeric codes. */
const rpcErrorText = (error: { code: number; errorCode: number }): string =>
  `Inline Protocol RPC failed (${error.code}, error ${error.errorCode})`

const decodePublicKeys = (keys: readonly InlineProtocolPublicKey[]): HandshakeRsaPublicKey[] => {
  if (keys.length === 0) throw new InlineProtocolV3Error("invalid-key", "At least one pinned RSA key is required")
  return keys.map((value) => {
    const profile = makeRsaPublicKey(decodeBase64Url(value.modulus), decodeBase64Url(value.exponent))
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

/**
 * Inflates a `gzip_packed` body. The TL wrapper is parsed by the shared
 * synchronous decoder; inflation goes through the host's (possibly async)
 * inflater, then the decoder's output rules are applied to its result.
 */
const unpackGzip = async (body: Uint8Array, gunzip: InlineProtocolGunzip): Promise<Uint8Array> => {
  let packed: Uint8Array | undefined
  decodeGzipPacked(body, (value) => {
    packed = value
    return new Uint8Array(4)
  }, MAXIMUM_GZIP_OUTPUT_BYTES)
  if (!packed) throw new InlineProtocolV3Error("protocol", "Invalid gzip_packed object")
  const unpacked = await gunzip(packed, MAXIMUM_GZIP_OUTPUT_BYTES)
  if (unpacked.length < 4 || unpacked.length > MAXIMUM_GZIP_OUTPUT_BYTES || unpacked.length % 4 !== 0) {
    throw new RangeError("Invalid decompressed MTProto object")
  }
  return unpacked
}

type PendingContent = {
  messageId: bigint
  sequenceNumber: number
  body: Uint8Array
  resolve: (value: { messageId: bigint; result: Uint8Array }) => void
  reject: (error: Error) => void
  timeout: InlineProtocolTimerHandle
  removeAbortListener?: () => void
}

type PendingProbe = {
  messageId: bigint
  sequenceNumber: number
  body: Uint8Array
  resolve: () => void
  reject: (error: Error) => void
  timeout: InlineProtocolTimerHandle
}

export class InlineProtocolV3Connection {
  readonly #options: InlineProtocolV3ConnectionOptions
  readonly #random: (length: number) => Uint8Array
  readonly #gunzip: InlineProtocolGunzip
  readonly #timers: InlineProtocolTimers
  readonly #wallClock: InlineProtocolClock
  readonly #maxPendingRequests: number
  readonly #maxPendingRequestBytes: number
  readonly #inbox: FrameInbox
  #messageIds = new MessageIdGenerator()
  readonly #sequenceNumbers = new SequenceNumberGenerator()
  readonly #clock: AuthenticatedServerClock
  /** Set once the clock comes from the handshake or an authenticated server record, not the device. */
  #clockAuthenticated = false
  /** Whether the record being handled arrived while the clock was still the device's estimate. */
  #recordPredatesClock = false
  /** The highest server message ID the clock was sampled from. */
  #clockMessageId: bigint | undefined
  /** The server message ID whose `new_session_created` or `bad_server_salt` last set the salt. */
  #saltMessageId: bigint | undefined
  readonly #receivedMessageIds = new ReceiveMessageWindow(RECEIVE_WINDOW_MESSAGES)
  readonly #sessionId: bigint
  readonly #rsaKeys: HandshakeRsaPublicKey[]
  readonly #uploads: NativeUploadClient
  #socket: InlineProtocolSocket | undefined
  #socketClosed = false
  readonly #closeWaiters: Array<() => void> = []
  #carrier: ObfuscatedClientHeader | undefined
  #authorization: InlineProtocolAuthorization | undefined
  readonly #pendingContent = new Map<bigint, PendingContent>()
  readonly #pendingProbes = new Map<bigint, PendingProbe>()
  #pendingRequestBytes = 0
  #receiveLoop: Promise<void> | undefined
  #closing = false
  #didNotifyClose = false
  #rotationTimer: InlineProtocolTimerHandle | undefined
  readonly #pendingAcknowledgements = new Set<bigint>()
  /** Containers sent, so a rejection of the whole container recovers its request. */
  readonly #sentContainers = new Map<bigint, { requestMessageId: bigint; sequenceNumber: number }>()
  #acknowledgementTimer: InlineProtocolTimerHandle | undefined
  #rotationDue = false

  private constructor(options: InlineProtocolV3ConnectionOptions) {
    this.#options = options
    const runtime = options.runtime
    this.#random = (length) => runtime.randomBytes(length)
    this.#gunzip = runtime.gunzip
    this.#timers = runtime.timers ?? globalInlineProtocolTimers()
    this.#wallClock = runtime.clock ?? globalInlineProtocolClock()
    const monotonic = this.#wallClock
    this.#clock = new AuthenticatedServerClock({ nowMilliseconds: () => monotonic.monotonicMilliseconds() })
    this.#inbox = new FrameInbox(MAXIMUM_INBOUND_BUFFER_BYTES, this.#timers)
    if (runtime.aes && getAesBackend() !== runtime.aes) setAesBackend(runtime.aes)
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
        // Only a first estimate for stamping the probe: records are not time-checked against
        // it, and rotation is not scheduled from it, until an authenticated server record arrives.
        connection.#clock.sample(Math.max(1, Math.floor(connection.#wallClock.wallMilliseconds() / 1_000)))
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

  /** Requests and probes admitted but not yet answered. */
  get pendingRequestCount(): number { return this.#pendingContent.size + this.#pendingProbes.size }

  async close(): Promise<void> {
    this.#closing = true
    if (this.#rotationTimer !== undefined) {
      this.#timers.clearTimeout(this.#rotationTimer)
      this.#rotationTimer = undefined
    }
    try {
      // The server keeps unacknowledged results for resend until it hears otherwise.
      if (this.#authorization && this.#carrier) this.#flushAcknowledgements()
    } catch {
      this.#takeAcknowledgements()
    }
    const socket = this.#socket
    this.#socket = undefined
    const closed = new InlineProtocolV3Error("closed", "Inline Protocol connection closed")
    this.#inbox.fail(closed)
    this.#failPendingContent(closed)
    if (!socket || this.#socketClosed || socket.readyState === InlineProtocolSocketState.closed) return
    await new Promise<void>((resolve) => {
      const timeout = this.#timers.setTimeout(resolve, CLOSE_WAIT_MS)
      this.#closeWaiters.push(() => {
        this.#timers.clearTimeout(timeout)
        resolve()
      })
      socket.close(1000, "Client closing")
    })
  }

  async invoke(request: RealtimeV3Request, options?: InlineProtocolInvokeOptions): Promise<RealtimeV3Response> {
    return await this.#invoke(request, options?.onDispatched, options?.signal)
  }

  async #invoke(
    request: RealtimeV3Request,
    onDispatched?: () => void,
    signal?: AbortSignal,
  ): Promise<RealtimeV3Response> {
    const payload = RealtimeV3Request.toBinary(request)
    // Layer 3 until servers advertise layer 4: a layer-3-only server (an older deploy
    // or the fallback host) closes the connection on any other layer. gzip_packed
    // results are still decoded if a server sends them.
    const result = await this.#sendContent(encodeInlineInvoke(payload, INLINE_REALTIME_LAYER), onDispatched, signal)
    let application
    try {
      application = decodeInlineApplicationObject(result)
    } catch (error) {
      if (serviceConstructor(result) === ServiceConstructor.rpcError) {
        const rpcError = decodeRpcError(result)
        if (rpcError.code === 503) {
          throw new InlineProtocolV3Error("rejected-before-execution", "Inline Protocol request was rejected before execution (503)")
        }
        if (rpcError.code === 504) {
          throw new InlineProtocolV3Error("commit-outcome-unknown", "Inline Protocol request outcome is unknown (504)")
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
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("unauthorized", rpcErrorText(response.body.rpcError))
    if (response.body.oneofKind !== "authBegin") throw new InlineProtocolV3Error("protocol", "Unexpected auth.begin response")
    return response.body.authBegin
  }

  async authComplete(request: AuthCompleteRequest): Promise<AuthCompleteResult> {
    const response = await this.#invokeMutation({ body: { oneofKind: "authComplete", authComplete: request } })
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("unauthorized", rpcErrorText(response.body.rpcError))
    if (response.body.oneofKind !== "authComplete") throw new InlineProtocolV3Error("protocol", "Unexpected auth.complete response")
    return response.body.authComplete
  }

  /**
   * Adds V3 authority to an existing bearer session. Must run on a connection
   * whose authorization is the permanent key being bound. Omit the token only to
   * recover a binding after a lost reply with the same permanent key.
   */
  async authUpgradeSession(bearerToken: string | undefined): Promise<AuthUpgradeSessionResult> {
    const response = await this.#invokeMutation({
      body: {
        oneofKind: "authUpgradeSession",
        authUpgradeSession: bearerToken === undefined ? {} : { bearerToken },
      },
    })
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("unauthorized", rpcErrorText(response.body.rpcError))
    if (response.body.oneofKind !== "authUpgradeSession") {
      throw new InlineProtocolV3Error("protocol", "Unexpected auth.upgradeSession response")
    }
    return response.body.authUpgradeSession
  }

  async callRpc(call: { method: Method; input: RpcInput }, signal?: AbortSignal): Promise<RpcResult["result"]> {
    const rpc: RpcCall = { method: call.method, input: normalizeRpcInput(call.method, call.input) }
    const request = { body: { oneofKind: "rpc" as const, rpc } }
    const response = readOnlyRpcMethods.has(rpc.method)
      ? await this.#invoke(request, undefined, signal)
      : await this.#invokeMutation(request, signal)
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("protocol", rpcErrorText(response.body.rpcError))
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
    const timeoutMs = this.#options.requestTimeoutMs ?? REQUEST_TIMEOUT_MS
    await new Promise<void>((resolve, reject) => {
      let pending: PendingProbe
      const timeout = this.#timers.setTimeout(() => {
        if (this.#pendingProbes.get(pingId) !== pending) return
        this.#pendingProbes.delete(pingId)
        this.#releasePending(body)
        reject(new InlineProtocolV3Error("timeout", `Inline Protocol response timed out after ${timeoutMs}ms`))
      }, timeoutMs)
      pending = { messageId, sequenceNumber, body, resolve, reject, timeout }
      this.#pendingProbes.set(pingId, pending)
      try {
        this.#sendEncrypted(messageId, sequenceNumber, body, true)
      } catch (error) {
        this.#pendingProbes.delete(pingId)
        this.#releasePending(body)
        this.#timers.clearTimeout(timeout)
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
    this.#clockAuthenticated = true
    this.#scheduleRotationTimer()
  }

  /** Samples only a new highest server message ID, so an older record cannot rewind the clock. */
  #sampleAuthenticatedServerMessage(messageId: bigint): void {
    if (this.#clockMessageId !== undefined && messageId <= this.#clockMessageId) return
    this.#clock.sampleMessageId(messageId)
    this.#clockMessageId = messageId
    this.#clockAuthenticated = true
    this.#scheduleRotationTimer()
  }

  #scheduleRotationTimer(): void {
    if (this.#rotationTimer !== undefined) {
      this.#timers.clearTimeout(this.#rotationTimer)
      this.#rotationTimer = undefined
    }
    const authorization = this.#authorization
    if (!authorization?.temporary || authorization.expiresAt === undefined || this.#closing || !this.#clockAuthenticated) return
    const boundary = authorization.expiresAt * 1_000 - TEMPORARY_KEY_ROTATION_MILLISECONDS
    const delay = boundary - this.#clock.nowMilliseconds()
    if (!Number.isFinite(delay) || delay <= 0) {
      this.#markRotationDue()
      return
    }
    const timer = this.#timers.setTimeout(() => {
      this.#rotationTimer = undefined
      this.#scheduleRotationTimer()
    }, Math.min(delay, MAXIMUM_TIMER_DELAY_MS))
    // In Node, an idle session must not keep the host process alive solely for rotation.
    this.#timers.unref?.(timer)
    this.#rotationTimer = timer
  }

  #markRotationDue(): void {
    if (this.#rotationDue || this.#closing) return
    this.#rotationDue = true
    void this.#options.onRotationDue?.()
  }

  async createHttpUpload(request: CreateHttpUploadRequest): Promise<CreateHttpUploadResult> {
    const response = await this.#invokeMutation({ body: { oneofKind: "createHttpUpload", createHttpUpload: request } })
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("protocol", rpcErrorText(response.body.rpcError))
    if (response.body.oneofKind !== "createHttpUpload") throw new InlineProtocolV3Error("protocol", "Unexpected upload response")
    return response.body.createHttpUpload
  }

  async finishHttpUpload(request: FinishHttpUploadRequest): Promise<FinishHttpUploadResult> {
    const response = await this.#invokeMutation({ body: { oneofKind: "finishHttpUpload", finishHttpUpload: request } })
    if (response.body.oneofKind === "rpcError") throw new InlineProtocolV3Error("protocol", rpcErrorText(response.body.rpcError))
    if (response.body.oneofKind !== "finishHttpUpload") throw new InlineProtocolV3Error("protocol", "Unexpected upload response")
    return response.body.finishHttpUpload
  }

  async #invokeMutation(request: RealtimeV3Request, signal?: AbortSignal): Promise<RealtimeV3Response> {
    let dispatched = false
    try {
      return await this.#invoke(request, () => { dispatched = true }, signal)
    } catch (error) {
      if (dispatched && error instanceof InlineProtocolV3Error &&
          ["closed", "protocol", "timeout", "unauthorized", "authorization-invalidated", "session-revoked"].includes(error.code)) {
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
    const temporary = this.#authorization
    if (!temporary?.temporary || temporary.expiresAt === undefined || permanent.temporary) {
      throw new InlineProtocolV3Error("unauthorized", "Temporary and permanent authorization keys are required")
    }
    const expiresAt = temporary.expiresAt
    let messageId = this.#nextClientMessageId()
    const sequenceNumber = this.#sequenceNumbers.next(true)
    const nonce = randomInt64(this.#random)
    const body = encodeBindTempAuthKey({
      permanentAuthKeyId: new DataView(permanent.keyId.buffer, permanent.keyId.byteOffset, 8).getBigInt64(0, true),
      nonce,
      expiresAt,
      encryptedMessage: createTemporaryKeyBindingProof({
        permanentAuthKey: permanent.key,
        temporaryAuthKey: temporary.key,
        temporarySessionId: this.#sessionId,
        messageId,
        nonce,
        expiresAt,
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
    let settled = false
    let resolveOpen: () => void = () => {}
    let rejectOpen: (error: Error) => void = () => {}
    const opened = new Promise<void>((resolve, reject) => {
      resolveOpen = resolve
      rejectOpen = reject
    })
    const settle = (error?: Error) => {
      if (settled) return
      settled = true
      if (error) rejectOpen(error)
      else resolveOpen()
    }
    const socket = this.#options.runtime.webSocket(this.#options.url, {
      onOpen: () => settle(),
      onMessage: (frame) => {
        try { this.#inbox.push(frame) }
        catch (error) { this.#inbox.fail(error instanceof Error ? error : new Error(String(error))) }
      },
      onClose: (code, reason) => {
        this.#socketClosed = true
        const error = code === INLINE_PROTOCOL_SESSION_REVOKED_CLOSE_CODE
          ? reason === INLINE_PROTOCOL_SESSION_REVOKED_CLOSE_REASON
            ? new InlineProtocolV3Error("session-revoked", "Inline Protocol session was revoked")
            : new InlineProtocolV3Error("authorization-invalidated", "Inline Protocol temporary authorization is unavailable")
          : new InlineProtocolV3Error("closed", "Inline Protocol connection closed")
        this.#inbox.fail(error)
        settle(error)
        for (const waiter of this.#closeWaiters.splice(0)) waiter()
      },
      onError: (cause) => {
        const error = new InlineProtocolV3Error("closed", "Inline Protocol WebSocket failed", { cause })
        this.#inbox.fail(error)
        settle(error)
      },
    })
    this.#socket = socket
    if (socket.readyState === InlineProtocolSocketState.open) settle()
    const timeout = this.#timers.setTimeout(
      () => settle(new InlineProtocolV3Error("timeout", "Inline Protocol connection timed out")),
      this.#options.connectTimeoutMs ?? CONNECT_TIMEOUT_MS,
    )
    try {
      await opened
    } finally {
      this.#timers.clearTimeout(timeout)
    }
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
    for (let round = 0; ; round += 1) {
      const messageId = this.#messageIds.next(this.#wallClock.wallMilliseconds(), randomLowBits(this.#random), 0)
      this.#sendPacket(encodeUnencryptedRecord(messageId, request))
      const response = decodeUnencryptedRecord(await this.#receivePacket(
        this.#options.requestTimeoutMs ?? REQUEST_TIMEOUT_MS,
      ))
      if (round === 0) requireBoundedPqChallenge(response.body, this.#random)
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
    const timeoutMs = this.#options.requestTimeoutMs ?? REQUEST_TIMEOUT_MS
    return await new Promise((resolve, reject) => {
      let pending: PendingContent
      const timeout = this.#timers.setTimeout(() => {
        if (this.#pendingContent.get(pending.messageId) !== pending) return
        this.#pendingContent.delete(pending.messageId)
        this.#releasePending(body)
        pending.removeAbortListener?.()
        reject(new InlineProtocolV3Error("timeout", `Inline Protocol response timed out after ${timeoutMs}ms`))
      }, timeoutMs)
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
        this.#timers.clearTimeout(pending.timeout)
        pending.removeAbortListener?.()
        const reason: unknown = signal?.reason
        reject(reason instanceof Error ? reason : new DOMException("The operation was aborted", "AbortError"))
      }
      signal?.addEventListener("abort", onAbort, { once: true })
      pending.removeAbortListener = () => signal?.removeEventListener("abort", onAbort)
      if (signal?.aborted) onAbort()
      if (this.#pendingContent.get(initialMessageId) !== pending) return
      try {
        this.#sendContentRecord(initialMessageId, sequenceNumber, body)
        onDispatched?.()
      } catch (error) {
        this.#pendingContent.delete(initialMessageId)
        this.#releasePending(body)
        this.#timers.clearTimeout(pending.timeout)
        pending.removeAbortListener?.()
        reject(error instanceof Error ? error : new Error(String(error)))
      }
    })
  }

  #startReceiveLoop(): void {
    if (this.#receiveLoop) return
    this.#receiveLoop = this.#runReceiveLoop().catch((error: unknown) => {
      // Only this module's own errors leave the loop: a decoder's error could carry decrypted fields.
      const failure = error instanceof InlineProtocolV3Error
        ? error
        : new InlineProtocolV3Error("protocol", "Inline Protocol receive failed")
      this.#failPendingContent(failure)
      this.#inbox.fail(failure)
      this.#socket?.close(1011, "Inline Protocol receive loop failed")
      if (!this.#closing && !this.#didNotifyClose) {
        this.#didNotifyClose = true
        this.#options.onClose?.(failure)
      }
    })
  }

  async #unpack(body: Uint8Array): Promise<Uint8Array> {
    return serviceConstructor(body) === ServiceConstructor.gzipPacked ? await unpackGzip(body, this.#gunzip) : body
  }

  async #runReceiveLoop(): Promise<void> {
    for (;;) {
      const record = await this.#receiveEncrypted()
      if (record.sequenceNumber % 2 === 1) this.#queueAcknowledgement(record.messageId)
      // Only a gzip_packed body awaits the (possibly asynchronous) inflater, so
      // uncompressed records keep the SDK's synchronous dispatch order.
      const body = serviceConstructor(record.body) === ServiceConstructor.gzipPacked
        ? await this.#unpack(record.body)
        : record.body
      const fields = { ...record, body }
      const constructor = serviceConstructor(fields.body)
      if (constructor === ServiceConstructor.newSessionCreated) {
        if (fields.body.length < 28) throw new InlineProtocolV3Error("protocol", "Invalid new_session_created")
        // A held-back older notice must not restore a salt a newer record replaced.
        if (this.#saltMessageId === undefined || fields.messageId > this.#saltMessageId) {
          this.#setServerSalt(readInt64LE(fields.body, 20), fields.messageId)
        }
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
        const resultBody = serviceConstructor(result.result) === ServiceConstructor.gzipPacked
          ? await this.#unpack(result.result)
          : result.result
        // The inflater may have yielded; a timeout, abort or close can have settled it meanwhile.
        if (this.#pendingContent.get(result.requestMessageId) !== pending) continue
        this.#pendingContent.delete(result.requestMessageId)
        for (const [containerId, container] of this.#sentContainers) {
          if (container.requestMessageId === result.requestMessageId) this.#sentContainers.delete(containerId)
        }
        this.#releasePending(pending.body)
        this.#timers.clearTimeout(pending.timeout)
        pending.removeAbortListener?.()
        pending.resolve({ messageId: result.requestMessageId, result: resultBody })
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
        this.#timers.clearTimeout(pending.timeout)
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
    const notification = decodeBadMessageNotification(body)
    const container = this.#sentContainers.get(notification.badMessageId)
    const carried = container && container.sequenceNumber === notification.badSequenceNumber
      ? this.#pendingContent.get(container.requestMessageId)
      : undefined
    if (container) this.#sentContainers.delete(notification.badMessageId)
    // A rejected container drops its acknowledgements and recovers its request alone.
    const bad = carried && container
      ? { ...notification, badMessageId: container.requestMessageId, badSequenceNumber: carried.sequenceNumber }
      : notification
    const pending = this.#pendingContent.get(bad.badMessageId)
    const probeEntry = [...this.#pendingProbes.entries()].find(([, value]) => value.messageId === bad.badMessageId)
    const target = pending ?? probeEntry?.[1]
    if (!target || bad.badSequenceNumber !== target.sequenceNumber) {
      throw new InlineProtocolV3Error("protocol", "Server rejected an unknown outgoing message")
    }
    if (pending) this.#pendingContent.delete(bad.badMessageId)
    if (probeEntry) this.#pendingProbes.delete(probeEntry[0])
    // 20 (older than the server's window) is a time correction only while the IDs still come from
    // the device clock; after that it means a lost message and stays fatal below.
    if (bad.errorCode === 16 || bad.errorCode === 17 || (bad.errorCode === 20 && this.#recordPredatesClock)) {
      this.#sampleAuthenticatedServerMessage(serverMessageId)
      // A device clock ahead of the server stamped the probe too high and the server
      // accepted nothing at that time, so the IDs restart from the server's clock.
      // Without this the generator never goes below the rejected ID and every resend
      // is rejected again.
      if (bad.errorCode === 17 && this.#recordPredatesClock) this.#messageIds = new MessageIdGenerator()
    }
    // It answers a request still pending under this exact ID and sequence number, so it is current.
    else if (bad.errorCode === 48 && bad.newServerSalt !== undefined) this.#setServerSalt(bad.newServerSalt, serverMessageId)
    else {
      this.#releasePending(target.body)
      this.#timers.clearTimeout(target.timeout)
      if (pending) pending.removeAbortListener?.()
      target.reject(new InlineProtocolV3Error("protocol", `Server rejected the outgoing message (${bad.errorCode})`))
      return
    }
    target.messageId = this.#nextClientMessageId()
    if (pending) this.#pendingContent.set(target.messageId, pending)
    else if (probeEntry) this.#pendingProbes.set(probeEntry[0], probeEntry[1])
    this.#sendEncrypted(target.messageId, target.sequenceNumber, target.body, true)
  }

  #failPendingContent(error: Error): void {
    const pending = [...this.#pendingContent.values()]
    this.#pendingContent.clear()
    for (const item of pending) {
      this.#timers.clearTimeout(item.timeout)
      item.removeAbortListener?.()
      item.reject(error)
    }
    const probes = [...this.#pendingProbes.values()]
    this.#pendingProbes.clear()
    this.#pendingRequestBytes = 0
    for (const probe of probes) {
      this.#timers.clearTimeout(probe.timeout)
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

  /**
   * The next authenticated server record that this connection has not seen.
   * A repeated message ID, or one below the receive window, is dropped
   * unprocessed and unacknowledged: someone who can see the stream could
   * otherwise re-inject an update, a salt or an older clock sample.
   */
  async #receiveEncrypted(): Promise<EncryptedRecordFields> {
    for (;;) {
      const fields = this.#openRecord(await this.#receivePacket())
      if (!this.#receivedMessageIds.claim(fields.messageId)) continue
      this.#recordPredatesClock = !this.#clockAuthenticated
      this.#sampleAuthenticatedServerMessage(fields.messageId)
      return fields
    }
  }

  /**
   * Decrypts and authenticates one server record. The salt of a server record is
   * not checked: it is the server's current salt, which the client learns from
   * the `bad_server_salt` such a record may carry. Until the clock is
   * authenticated (a cached key's first record), the time window is not applied
   * either; the fresh session ID already rules out records from earlier sessions.
   * Errors carry no decrypted field.
   */
  #openRecord(packet: Uint8Array): EncryptedRecordFields {
    const authorization = this.#authorization
    if (!authorization) throw new InlineProtocolV3Error("unauthorized", "Authorization-key handshake is incomplete")
    try {
      return decryptRecord(packet, authorization.key, {
        direction: "server-to-client",
        sessionId: this.#sessionId,
        validServerSalts: new Set([authorization.serverSalt]),
        nowSeconds: this.#clock.nowMilliseconds() / 1_000,
      })
    } catch (error) {
      // Thrown only after the record authenticated; the salt is checked last, so 48 means all else held.
      if (error instanceof RecoverableEncryptedRecordError &&
          (error.errorCode === 48 || (!this.#clockAuthenticated && (error.errorCode === 17 || error.errorCode === 20)))) {
        return error.fields
      }
      const reason = error instanceof RecoverableEncryptedRecordError
        ? error.errorCode === 18 ? "direction" : "time"
        : "authentication"
      throw new InlineProtocolV3Error("protocol", `Inline Protocol rejected a server record (${reason})`)
    }
  }

  #queueAcknowledgement(messageId: bigint): void {
    this.#pendingAcknowledgements.add(messageId)
    if (this.#pendingAcknowledgements.size >= ACK_FLUSH_PENDING) {
      this.#flushAcknowledgements()
      return
    }
    if (this.#acknowledgementTimer === undefined) {
      this.#acknowledgementTimer = this.#timers.setTimeout(() => {
        this.#acknowledgementTimer = undefined
        try {
          this.#flushAcknowledgements()
        } catch {
          // A closed carrier has nothing left to acknowledge to.
        }
      }, ACK_FLUSH_DELAY_MS)
      this.#timers.unref?.(this.#acknowledgementTimer)
    }
  }

  #takeAcknowledgements(): bigint[] {
    if (this.#acknowledgementTimer !== undefined) this.#timers.clearTimeout(this.#acknowledgementTimer)
    this.#acknowledgementTimer = undefined
    const messageIds = [...this.#pendingAcknowledgements]
    this.#pendingAcknowledgements.clear()
    return messageIds
  }

  #flushAcknowledgements(): void {
    const messageIds = this.#takeAcknowledgements()
    if (messageIds.length === 0) return
    this.#sendEncrypted(this.#nextClientMessageId(), this.#sequenceNumbers.next(false), encodeMsgsAck(messageIds), false)
  }

  /**
   * Sends a content request, carrying pending acknowledgements in one container
   * `[request, msgs_ack]` when it is an application invoke. Child IDs precede the
   * container's, and the non-content seqnos follow the request's.
   */
  #sendContentRecord(messageId: bigint, sequenceNumber: number, body: Uint8Array): void {
    const acknowledgements = serviceConstructor(body) === INLINE_INVOKE_CONSTRUCTOR
      ? this.#takeAcknowledgements()
      : []
    if (acknowledgements.length === 0) {
      this.#sendEncrypted(messageId, sequenceNumber, body, true)
      return
    }
    const acknowledgementMessageId = this.#nextClientMessageId()
    const nonContentSequenceNumber = this.#sequenceNumbers.next(false)
    const container = encodeMessageContainer([
      { messageId, sequenceNumber, body },
      { messageId: acknowledgementMessageId, sequenceNumber: nonContentSequenceNumber, body: encodeMsgsAck(acknowledgements) },
    ])
    const containerMessageId = this.#nextClientMessageId()
    if (this.#sentContainers.size >= 128) {
      const oldest = this.#sentContainers.keys().next().value
      if (oldest !== undefined) this.#sentContainers.delete(oldest)
    }
    this.#sentContainers.set(containerMessageId, { requestMessageId: messageId, sequenceNumber: nonContentSequenceNumber })
    this.#sendEncrypted(containerMessageId, nonContentSequenceNumber, container, true)
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

  #setServerSalt(serverSalt: bigint, messageId: bigint): void {
    if (!this.#authorization) throw new InlineProtocolV3Error("unauthorized", "Authorization-key handshake is incomplete")
    this.#authorization.serverSalt = serverSalt
    if (this.#saltMessageId === undefined || messageId > this.#saltMessageId) this.#saltMessageId = messageId
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
    if (!socket || this.#socketClosed || socket.readyState !== InlineProtocolSocketState.open) {
      throw new InlineProtocolV3Error("closed", "Inline Protocol connection is not open")
    }
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
