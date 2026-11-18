import {
  ConnectionError_Reason,
  ServerProtocolMessage,
  type ClientMessage,
  type RealtimeV3Request,
  type RealtimeV3Response,
  type RealtimeV3Update,
} from "@inline-chat/protocol/core"
import {
  InlineProtocolV3Connection,
  InlineProtocolV3Error,
  globalInlineProtocolTimers,
  type InlineProtocolPublicKey,
  type InlineProtocolRuntime,
  type InlineProtocolTimers,
} from "@inline-chat/protocol/secure/connection"
import { Log, type LogLevel } from "@inline/log"
import { AsyncChannel } from "../../utils/async-channel"
import type { TransportEvent } from "../types"
import { TransportError, type Transport } from "./transport"
import { cloneInlineProtocolCredentials, type InlineProtocolKeyStore } from "./v3-credentials"
import { v3ConnectionInit } from "./v3-connection-init"

type State = "idle" | "connecting" | "connected"

const PENDING_UPDATE_CAPACITY = 256
const REJECTED_BEFORE_EXECUTION_RETRY_LIMIT = 2
const REJECTED_BEFORE_EXECUTION_RETRY_DELAY_MS = 1_000

export type V3TransportOptions = {
  /** The V3 endpoint, `wss://…/realtime/v3`. */
  url: string
  runtime: InlineProtocolRuntime
  /** Pinned server keys; needed to create a temporary key (every cold start without a cached one). */
  rsaPublicKeys: readonly InlineProtocolPublicKey[]
  keyStore: InlineProtocolKeyStore
  /** The signed-in account, or null when signed out. Read at every start. */
  accountId: () => string | null
  requestTimeoutMs?: number
  connectTimeoutMs?: number
  logLevel?: LogLevel
  logger?: Log
}

export class V3TransportError extends Error {
  constructor(readonly code: "no-credentials" | "superseded", message: string) {
    super(message)
    this.name = `V3TransportError:${code}`
  }
}

const isV3Error = (error: unknown, ...codes: InlineProtocolV3Error["code"][]): error is InlineProtocolV3Error =>
  error instanceof InlineProtocolV3Error && codes.includes(error.code)

/** A short, fixed category for logs and disconnect reasons; never error text. */
const failureCategory = (error: unknown): string => {
  if (error instanceof InlineProtocolV3Error) return `v3-${error.code}`
  if (error instanceof V3TransportError) return `v3-${error.code}`
  return "v3-unexpected"
}

/**
 * `Transport` over Inline Protocol V3, for the web core's `ProtocolClient`.
 *
 * One `start()` is one connection attempt, like the V2 transport: it emits
 * `connecting`, opens an authenticated V3 connection (cached temporary key, or
 * a fresh temporary key bound to the stored permanent key), then `connected`.
 * A loss emits `disconnected` and returns to idle; the connection manager owns
 * retries and backoff.
 *
 * `ClientMessage`s map onto V3 as follows:
 * - `connectionInit` → V3 `connection_init` (token stripped); its
 *   `connection_open` (with `upgraded_session_transport`) is emitted as a
 *   `connectionOpen` server message, so the protocol client's handshake is unchanged.
 * - `rpcCall` → V3 `rpc`; `send` resolves once the record is written, the result
 *   arrives later as `rpcResult`/`rpcError` with `reqMsgId` = the message ID.
 * - `ping` → authenticated MTProto ping; the pong arrives as `pong`.
 * - `ack` → nothing (V3 acknowledges at the record layer).
 */
export class V3Transport implements Transport {
  readonly events = new AsyncChannel<TransportEvent>()

  readonly #options: V3TransportOptions
  readonly #log: Log
  readonly #timers: InlineProtocolTimers
  #state: State = "idle"
  #generation = 0
  #connection: InlineProtocolV3Connection | undefined
  #accountId: string | undefined
  #activeRequests = 0
  #rotationDue = false
  #opened = false
  #pendingUpdates: RealtimeV3Update[] = []
  /** A temporary key whose rotation came due; skipped when it is next read from the store. */
  #retiredTemporaryKeyId: string | undefined

  constructor(options: V3TransportOptions) {
    this.#options = options
    this.#log = options.logger ?? new Log("RealtimeV3.Transport", options.logLevel)
    this.#timers = options.runtime.timers ?? globalInlineProtocolTimers()
  }

  get state(): State {
    return this.#state
  }

  async start() {
    if (this.#state !== "idle") return
    const generation = ++this.#generation
    this.#state = "connecting"
    this.#opened = false
    this.#rotationDue = false
    this.#pendingUpdates = []
    await this.events.send({ type: "connecting" })
    let connection: InlineProtocolV3Connection | undefined
    try {
      connection = await this.#open(generation)
      this.#requireCurrent(generation)
    } catch (error) {
      await connection?.close()
      if (generation !== this.#generation) return
      this.#state = "idle"
      this.#log.warn("transport.v3.start_failed", { reason: failureCategory(error) })
      if (isV3Error(error, "session-revoked")) {
        await this.#emitAuthorizationRejected()
        return
      }
      await this.events.send({ type: "disconnected", reason: failureCategory(error) })
      return
    }
    this.#connection = connection
    this.#state = "connected"
    this.#log.debug("transport.v3.connected", {})
    await this.events.send({ type: "connected" })
  }

  async stop() {
    ++this.#generation
    const connection = this.#connection
    this.#connection = undefined
    this.#pendingUpdates = []
    if (this.#state === "idle" && !connection) return
    const wasIdle = this.#state === "idle"
    this.#state = "idle"
    await connection?.close()
    if (!wasIdle) await this.events.send({ type: "stopping" })
  }

  async send(message: ClientMessage) {
    const connection = this.#connection
    if (this.#state !== "connected" || !connection) throw TransportError.notConnected()
    const generation = this.#generation
    switch (message.body.oneofKind) {
      case "connectionInit": {
        const init = v3ConnectionInit(message.body.connectionInit)
        await this.#dispatch(connection, generation, { body: { oneofKind: "connectionInit", connectionInit: init } },
          (response) => this.#connectionOpened(connection, generation, message.id, response))
        return
      }
      case "rpcCall": {
        const request: RealtimeV3Request = { body: { oneofKind: "rpc", rpc: message.body.rpcCall } }
        await this.#dispatch(connection, generation, request,
          (response) => this.#deliverRpc(connection, generation, message.id, response))
        return
      }
      case "ping": {
        const nonce = message.body.ping.nonce
        this.#admit()
        let probe: Promise<void>
        try {
          // MTProto ping IDs are signed 64-bit; the V2 nonce is unsigned.
          probe = connection.ping(BigInt.asIntN(64, nonce))
        } catch (error) {
          this.#settle()
          throw this.#admissionError(error)
        }
        void probe.then(
          async () => {
            try {
              if (!this.#isCurrent(connection, generation)) return
              await this.events.send({
                type: "message",
                message: ServerProtocolMessage.create({ body: { oneofKind: "pong", pong: { nonce } } }),
              })
            } finally {
              this.#settle()
            }
          },
          async (error: unknown) => {
            this.#settle()
            if (isV3Error(error, "rotation-due", "capacity-exceeded")) return
            await this.#lose(connection, generation, error)
          },
        )
        return
      }
      case "ack":
      case undefined:
        return
    }
  }

  getDiagnostics() {
    return {
      kind: "inline-protocol-v3" as const,
      state: this.#state,
      activeRequests: this.#activeRequests,
      rotationDue: this.#rotationDue,
    }
  }

  async #open(generation: number): Promise<InlineProtocolV3Connection> {
    const accountId = this.#options.accountId()
    if (!accountId) throw new V3TransportError("no-credentials", "No signed-in account")
    const stored = await this.#options.keyStore.get(accountId)
    this.#requireCurrent(generation)
    if (!stored || stored.state !== "bound") {
      throw new V3TransportError("no-credentials", "No bound V3 permanent key for this account")
    }
    this.#accountId = accountId
    const temporary = stored.temporary
    const owner: { connection?: InlineProtocolV3Connection; closeError?: Error } = {}
    const callbacks = {
      onUpdate: (update: RealtimeV3Update) => {
        if (owner.connection) void this.#forwardUpdate(owner.connection, generation, update)
      },
      onClose: (error: Error) => {
        if (owner.connection && this.#connection === owner.connection) void this.#lose(owner.connection, generation, error)
        else owner.closeError ??= error
      },
      // Let the authenticated record that crossed the boundary finish delivery first.
      onRotationDue: () => {
        this.#timers.setTimeout(() => {
          if (owner.connection) this.#rotationBecameDue(owner.connection, generation)
        }, 0)
      },
    }
    const base = {
      url: this.#options.url,
      runtime: this.#options.runtime,
      ...(this.#options.requestTimeoutMs != null ? { requestTimeoutMs: this.#options.requestTimeoutMs } : {}),
      ...(this.#options.connectTimeoutMs != null ? { connectTimeoutMs: this.#options.connectTimeoutMs } : {}),
      ...callbacks,
    }

    const retired = temporary && keyIdHex(temporary.keyId) === this.#retiredTemporaryKeyId
    if (temporary?.expiresAt !== undefined && !retired) {
      let cached: InlineProtocolV3Connection | undefined
      try {
        cached = await InlineProtocolV3Connection.connect({ ...base, rsaPublicKeys: [], authorization: temporary })
        owner.connection = cached
        this.#requireCurrent(generation)
        await cached.probeTemporaryAuthorization()
        if (owner.closeError) throw owner.closeError
        this.#requireCurrent(generation)
        if (!cached.temporaryAuthorizationNeedsRotation()) return cached
        this.#log.debug("transport.v3.cached_key_rotation_due", {})
      } catch (error) {
        await cached?.close()
        // Only a rejected key is replaced; a network failure keeps it for the next attempt. A
        // revocation close is unauthenticated, so it is checked the same way: binding a new
        // temporary key makes the server prove the revocation against the permanent key.
        if (!isV3Error(error, "authorization-invalidated", "session-revoked")) throw error
        this.#log.warn("transport.v3.cached_key_rejected", {})
      }
      await cached?.close()
      owner.connection = undefined
      owner.closeError = undefined
      this.#requireCurrent(generation)
    }

    if (this.#options.rsaPublicKeys.length === 0) {
      throw new InlineProtocolV3Error("invalid-key", "Pinned RSA keys are required to create a temporary key")
    }
    let replacement: InlineProtocolV3Connection | undefined
    try {
      replacement = await InlineProtocolV3Connection.connect({
        ...base,
        rsaPublicKeys: this.#options.rsaPublicKeys,
        temporary: true,
      })
      owner.connection = replacement
      this.#requireCurrent(generation)
      await replacement.bindTemporary(stored.permanent)
      await replacement.ping()
      if (owner.closeError) throw owner.closeError
      this.#requireCurrent(generation)
      // Persist only for the account that is still signed in, and only after the binding is proven.
      if (this.#options.accountId() !== accountId) throw new V3TransportError("superseded", "Account changed")
      const current = await this.#options.keyStore.get(accountId)
      this.#requireCurrent(generation)
      if (current && current.state === "bound" && keyIdHex(current.permanent.keyId) === keyIdHex(stored.permanent.keyId)) {
        const next = cloneInlineProtocolCredentials(current)
        next.temporary = replacement.authorization
        await this.#options.keyStore.set(accountId, next)
        this.#requireCurrent(generation)
      } else {
        throw new V3TransportError("superseded", "Stored V3 credentials changed during connect")
      }
      return replacement
    } catch (error) {
      await replacement?.close()
      throw error
    }
  }

  /** Writes one request; resolves when it is on the socket. The response is handled by `onResponse`. */
  async #dispatch(
    connection: InlineProtocolV3Connection,
    generation: number,
    request: RealtimeV3Request,
    onResponse: (response: RealtimeV3Response) => Promise<void>,
  ) {
    this.#admit()
    let dispatched = false
    try {
      await new Promise<void>((resolve, reject) => {
        const attempt = (retry: number) => {
          let attemptDispatched = false
          connection.invoke(request, {
            onDispatched: () => {
              attemptDispatched = true
              if (!dispatched) {
                dispatched = true
                resolve()
              }
            },
          }).then(
            async (response) => {
              // Deliver before settling: settling can start a rotation that retires this connection.
              try {
                await onResponse(response)
              } finally {
                this.#settle()
              }
            },
            async (error: unknown) => {
              if (!attemptDispatched && !dispatched) {
                this.#settle()
                reject(this.#admissionError(error))
                return
              }
              // The server proved this request never executed; redeliver it with a fresh record.
              if (isV3Error(error, "rejected-before-execution") && retry < REJECTED_BEFORE_EXECUTION_RETRY_LIMIT) {
                this.#timers.setTimeout(() => {
                  if (!this.#isCurrent(connection, generation)) {
                    this.#settle()
                    return
                  }
                  attempt(retry + 1)
                }, REJECTED_BEFORE_EXECUTION_RETRY_DELAY_MS)
                return
              }
              this.#settle()
              // The V2 model has no per-request uncertainty: a request that lost its
              // answer is treated as a lost connection, and the core's normal
              // reconnect and resend path decides what happens to it.
              await this.#lose(connection, generation, error)
            },
          )
        }
        attempt(0)
      })
    } catch (error) {
      if (!dispatched) throw error
    }
  }

  #admit() {
    if (this.#rotationDue) {
      this.#maybeRotate()
      throw TransportError.notConnected()
    }
    this.#activeRequests += 1
  }

  #settle() {
    this.#activeRequests = Math.max(0, this.#activeRequests - 1)
    this.#maybeRotate()
  }

  #admissionError(error: unknown): Error {
    if (isV3Error(error, "rotation-due")) {
      const connection = this.#connection
      if (connection) this.#rotationBecameDue(connection, this.#generation)
      return TransportError.notConnected()
    }
    if (isV3Error(error, "closed")) return TransportError.notConnected()
    return TransportError.sendFailed(error)
  }

  async #connectionOpened(
    connection: InlineProtocolV3Connection,
    generation: number,
    messageId: bigint,
    response: RealtimeV3Response,
  ) {
    if (!this.#isCurrent(connection, generation)) return
    // An older server answers init with an RPC error; the key is already verified, so open anyway.
    const connectionOpen = response.body.oneofKind === "connectionOpen" ? response.body.connectionOpen : {}
    this.#opened = true
    await this.events.send({
      type: "message",
      message: ServerProtocolMessage.create({ id: messageId, body: { oneofKind: "connectionOpen", connectionOpen } }),
    })
    const pending = this.#pendingUpdates
    this.#pendingUpdates = []
    for (const update of pending) await this.#emitUpdate(update)
  }

  async #deliverRpc(
    connection: InlineProtocolV3Connection,
    generation: number,
    messageId: bigint,
    response: RealtimeV3Response,
  ) {
    if (!this.#isCurrent(connection, generation)) return
    if (response.body.oneofKind === "rpcResult") {
      await this.events.send({
        type: "message",
        message: ServerProtocolMessage.create({
          body: { oneofKind: "rpcResult", rpcResult: { ...response.body.rpcResult, reqMsgId: messageId } },
        }),
      })
      return
    }
    if (response.body.oneofKind === "rpcError") {
      await this.events.send({
        type: "message",
        message: ServerProtocolMessage.create({
          body: { oneofKind: "rpcError", rpcError: { ...response.body.rpcError, reqMsgId: messageId } },
        }),
      })
      return
    }
    await this.#lose(connection, generation, new InlineProtocolV3Error("protocol", "Unexpected V3 RPC response"))
  }

  async #forwardUpdate(connection: InlineProtocolV3Connection, generation: number, update: RealtimeV3Update) {
    if (!update.message) return
    if (generation !== this.#generation || this.#state === "idle") return
    // Updates can overtake the init response; hold them until the protocol client has opened.
    if (this.#state === "connecting" || !this.#opened) {
      if (this.#pendingUpdates.length >= PENDING_UPDATE_CAPACITY) {
        await this.#lose(connection, generation, new InlineProtocolV3Error("capacity-exceeded", "Update buffer exceeded"))
        return
      }
      this.#pendingUpdates.push(update)
      return
    }
    if (this.#connection !== connection) return
    await this.#emitUpdate(update)
  }

  async #emitUpdate(update: RealtimeV3Update) {
    if (!update.message) return
    await this.events.send({
      type: "message",
      message: ServerProtocolMessage.create({ body: { oneofKind: "message", message: update.message } }),
    })
  }

  #rotationBecameDue(connection: InlineProtocolV3Connection, generation: number) {
    if (generation !== this.#generation || this.#connection !== connection || this.#state !== "connected") return
    this.#rotationDue = true
    this.#retiredTemporaryKeyId = keyIdHex(connection.authorization.keyId)
    this.#maybeRotate()
  }

  /** Once nothing is in flight, close and report a disconnect; the next start mints a fresh temporary key. */
  #maybeRotate() {
    const connection = this.#connection
    if (!this.#rotationDue || this.#activeRequests !== 0 || this.#state !== "connected" || !connection) return
    this.#log.debug("transport.v3.rotating_temporary_key", {})
    void this.#lose(connection, this.#generation, undefined, "v3-temporary-key-rotation")
  }

  async #lose(connection: InlineProtocolV3Connection, generation: number, error: unknown, reason?: string) {
    if (!this.#isCurrent(connection, generation)) return
    ++this.#generation
    this.#connection = undefined
    this.#state = "idle"
    this.#pendingUpdates = []
    if (isV3Error(error, "authorization-invalidated", "session-revoked")) {
      // The temporary key is gone (for example a server restart), or a close claims revocation;
      // the next start replaces the key once, and the binding settles which it was.
      this.#retiredTemporaryKeyId = keyIdHex(connection.authorization.keyId)
    }
    const category = reason ?? (isV3Error(error, "session-revoked") ? "v3-authorization-recheck" : failureCategory(error))
    this.#log.warn("transport.v3.connection_lost", { reason: category })
    await connection.close()
    await this.events.send({ type: "disconnected", reason: category })
  }

  /**
   * The binding of a new temporary key was answered with a revocation close. The
   * close frame is not covered by V3's cryptography, so this stops the session
   * for re-authentication (`INVALID_AUTH`) and erases nothing. `SESSION_REVOKED`,
   * which signs out and erases, is never derived from a V3 close: it needs a
   * revocation inside an authenticated record, which the server does not send yet.
   */
  async #emitAuthorizationRejected() {
    await this.events.send({
      type: "message",
      message: ServerProtocolMessage.create({
        body: { oneofKind: "connectionError", connectionError: { reason: ConnectionError_Reason.INVALID_AUTH } },
      }),
    })
    await this.events.send({ type: "disconnected", reason: "v3-session-revoked" })
  }

  #isCurrent(connection: InlineProtocolV3Connection, generation: number) {
    return generation === this.#generation && this.#connection === connection && this.#state === "connected"
  }

  #requireCurrent(generation: number) {
    if (generation !== this.#generation || this.#state === "idle") {
      throw new V3TransportError("superseded", "Connection attempt was superseded")
    }
  }

  /** The account whose credentials the current connection uses. */
  get accountId(): string | undefined {
    return this.#accountId
  }
}

const keyIdHex = (keyId: Uint8Array) => Array.from(keyId, (byte) => byte.toString(16).padStart(2, "0")).join("")

/** Derives the V3 endpoint from the V2 realtime URL (`…/realtime` → `…/realtime/v3`), as the Apple clients do. */
export const v3RealtimeUrl = (realtimeUrl: string): string => {
  const trimmed = realtimeUrl.replace(/\/+$/, "")
  return trimmed.endsWith("/realtime") ? `${trimmed}/v3` : `${trimmed}/realtime/v3`
}

