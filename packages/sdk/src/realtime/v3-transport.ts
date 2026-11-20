import {
  ClientMessage,
  ConnectionError_Reason,
  RealtimeV3Update,
  ServerProtocolMessage,
} from "@inline-chat/protocol/core"
import { AsyncChannel } from "../utils/async-channel.js"
import type { InlineSdkLogger } from "../sdk/logger.js"
import { TransportError, type Transport, type TransportReconnectOptions } from "./transport.js"
import {
  InlineProtocolV3Connection,
  InlineProtocolV3Error,
  type InlineProtocolPublicKey,
} from "./v3-connection.js"
import type { InlineProtocolV3Credentials } from "./v3-client.js"
import type { TransportEvent } from "./types.js"
import { TRANSFER_RPC_METHODS } from "@inline-chat/protocol/transfers"

type State = "idle" | "connecting" | "connected"
const pendingUpdateCapacity = 256
const pendingUpdateByteCapacity = 8 * 1024 * 1024
const transportEventByteCapacity = 8 * 1024 * 1024
const rejectedBeforeExecutionRetryLimit = 2
const rejectedBeforeExecutionRetryDelayMs = 1_000
// Reconnect backoff: full jitter over min(60 s, 1 s * 2^(failures - 1)). The first
// retry after a close is 0-1 s, so a fleet does not reconnect in lockstep after a deploy.
const reconnectBaseDelayMs = 1_000
const reconnectMaxDelayMs = 60_000
// start() stays fail-fast so its caller owns first-connect retries; reconnects retry without a limit.
const startAuthorizationRecoveryAttemptLimit = 3
// The server closes an idle transfer socket after 120 s; close ours first.
const transferIdleTimeoutMs = 110_000

type TransferConnection = {
  generation: number
  opening: Promise<InlineProtocolV3Connection>
  connection?: InlineProtocolV3Connection
  active: number
  idleTimer?: ReturnType<typeof setTimeout>
}

/** A transfer connection failure the main connection can absorb: every transfer RPC is idempotent. */
const transferCarrierFailed = (error: unknown): boolean =>
  error instanceof InlineProtocolV3Error && error.code !== "unauthorized" && error.code !== "session-revoked"

const transportEventByteLength = (event: TransportEvent): number =>
  event.type === "message" ? ServerProtocolMessage.toBinary(event.message).byteLength : 32

/**
 * Why the transport stopped reconnecting on its own. It stays offline until the
 * host calls start() again.
 */
export type InlineProtocolV3TransportOfflineReason =
  /** The server confirmed the session was revoked. The SDK also raises a SESSION_REVOKED authentication error. */
  | "session-revoked"
  /**
   * The server refused to establish or bind a replacement temporary key for the
   * stored permanent authorization (for example the permanent key was
   * invalidated). Re-authenticate to get new credentials.
   */
  | "authorization-rejected"
  /** onCredentials failed for a replacement temporary key, so the key was never used. */
  | "credential-persistence-failed"
  /** start() could not open a connection; its promise rejects with the same error. */
  | "connect-failed"

/** Observable transport lifecycle, for host health checks. */
export type InlineProtocolV3TransportState =
  | { kind: "connecting" }
  | { kind: "connected" }
  /**
   * A transient failure (closed socket, timeout, server restart). The transport
   * retries by itself after `retryInMs`; `attempt` counts consecutive failures
   * since the last successful connection. `replacingAuthorization` is true while
   * a rejected temporary key is being replaced.
   */
  | { kind: "recovering"; attempt: number; retryInMs: number; replacingAuthorization: boolean; error: Error }
  /** Automatic recovery stopped; see InlineProtocolV3TransportOfflineReason. */
  | { kind: "offline"; reason: InlineProtocolV3TransportOfflineReason; error: Error }
  /** Not started, or stopped by the host. */
  | { kind: "stopped" }

export type InlineProtocolV3TransportOptions = {
  url: string
  rsaPublicKeys: readonly InlineProtocolPublicKey[]
  credentials: InlineProtocolV3Credentials
  requestTimeoutMs?: number
  logger?: InlineSdkLogger
  onCredentials?: (credentials: InlineProtocolV3Credentials) => void | Promise<void>
  /**
   * Called on a microtask after each lifecycle change, in order, so it may call
   * stop() or start(). Errors it throws are logged and ignored.
   */
  onStateChange?: (state: InlineProtocolV3TransportState) => void
  /** Uniform [0, 1) source for reconnect jitter. Defaults to Math.random. */
  random?: () => number
}

const cloneAuthorization = (value: InlineProtocolV3Credentials["permanent"]) => ({
  ...value,
  key: value.key.slice(),
  keyId: value.keyId.slice(),
})

const cloneCredentials = (value: InlineProtocolV3Credentials): InlineProtocolV3Credentials => ({
  permanent: cloneAuthorization(value.permanent),
  ...(value.temporary ? { temporary: cloneAuthorization(value.temporary) } : {}),
})

const isSessionRevoked = (error: unknown): error is InlineProtocolV3Error =>
  error instanceof InlineProtocolV3Error && error.code === "session-revoked"

const isAuthorizationInvalidated = (error: unknown): error is InlineProtocolV3Error =>
  error instanceof InlineProtocolV3Error && error.code === "authorization-invalidated"

const isTransientNetworkFailure = (error: unknown): error is InlineProtocolV3Error =>
  error instanceof InlineProtocolV3Error && (error.code === "closed" || error.code === "timeout")

const asError = (error: unknown): Error => error instanceof Error ? error : new Error(String(error))

type Sleep = { timer: ReturnType<typeof setTimeout>; resolve: () => void }

export class InlineProtocolV3Transport implements Transport {
  readonly events = new AsyncChannel<TransportEvent>(256, {
    capacityBytes: transportEventByteCapacity,
    byteLength: transportEventByteLength,
  })

  readonly #options: InlineProtocolV3TransportOptions
  readonly #log: InlineSdkLogger
  #credentials: InlineProtocolV3Credentials
  #connection: InlineProtocolV3Connection | undefined
  #state: State = "idle"
  #reconnectingGeneration: number | undefined
  // A close that arrived while #open was publishing; reconnect with it once that generation finishes.
  #reconnectAfterOpen: Error | undefined
  #generation = 0
  // Consecutive failures since the last successful connection; drives backoff.
  #failures = 0
  #status: InlineProtocolV3TransportState = { kind: "stopped" }
  // Backoff waits inside a generation; a new generation resolves them early so they never outlive stop().
  readonly #sleeps = new Set<Sleep>()
  readonly #persistenceFailures = new WeakSet<object>()
  #retryTimer: ReturnType<typeof setTimeout> | undefined
  #pendingUpdates: RealtimeV3Update[] = []
  #pendingUpdateBytes = 0
  #flushingUpdates = false
  #rotationDue = false
  #activeRequests = 0
  #transfer: TransferConnection | undefined
  // A rejected temporary key is being replaced; only transient bootstrap failures retry.
  #recoveringAuthorization = false

  constructor(options: InlineProtocolV3TransportOptions) {
    this.#options = options
    this.#log = options.logger ?? {}
    this.#credentials = cloneCredentials(options.credentials)
  }

  async start(): Promise<void> {
    if (this.#state !== "idle") return
    this.#state = "connecting"
    this.#recoveringAuthorization = false
    this.#reconnectAfterOpen = undefined
    this.#flushingUpdates = false
    this.#rotationDue = false
    this.#failures = 0
    const generation = this.#nextGeneration()
    this.#pendingUpdates = []
    this.#pendingUpdateBytes = 0
    this.#publish({ kind: "connecting" })
    await this.events.send({ type: "connecting" })
    try {
      await this.#open(generation, startAuthorizationRecoveryAttemptLimit)
    } catch (error) {
      if (isSessionRevoked(error)) {
        await this.#authenticationInvalidated(generation, error)
        return
      }
      if (this.#generation === generation && !this.#isIdle()) {
        this.#state = "idle"
        this.#publish({ kind: "offline", reason: "connect-failed", error: asError(error) })
      }
      throw error
    }
  }

  async stop(): Promise<void> {
    this.#nextGeneration()
    this.#reconnectingGeneration = undefined
    this.#failures = 0
    if (this.#retryTimer) {
      clearTimeout(this.#retryTimer)
      this.#retryTimer = undefined
    }
    if (this.#state === "idle" && !this.#connection) return
    this.#state = "idle"
    this.#publish({ kind: "stopped" })
    this.#flushingUpdates = false
    this.#pendingUpdates = []
    this.#pendingUpdateBytes = 0
    await this.events.send({ type: "stopping" })
    const connection = this.#connection
    this.#connection = undefined
    this.#closeTransfer()
    await connection?.close()
  }

  async stopConnection(): Promise<void> {
    this.#nextGeneration()
    this.#reconnectingGeneration = undefined
    const connection = this.#connection
    this.#connection = undefined
    if (this.#state !== "idle") this.#state = "connecting"
    this.#closeTransfer()
    await connection?.close()
  }

  /**
   * Reopens now. A pending backoff retry is replaced by this attempt; if it
   * fails, the next retry still uses the accumulated backoff. `skipDelay` is
   * accepted for the Transport contract: this transport never delays an
   * explicit reconnect.
   */
  async reconnect(_options?: TransportReconnectOptions): Promise<void> {
    await this.#reconnect()
  }

  /** `failure` set: the active connection failed, so wait a jittered backoff before reopening. */
  async #reconnect(failure?: Error): Promise<void> {
    if (this.#state === "idle" || this.#reconnectingGeneration !== undefined) return
    this.#reconnectAfterOpen = undefined
    if (this.#retryTimer) {
      clearTimeout(this.#retryTimer)
      this.#retryTimer = undefined
    }
    const generation = this.#nextGeneration()
    this.#reconnectingGeneration = generation
    this.#pendingUpdates = []
    this.#pendingUpdateBytes = 0
    let delayMs = 0
    if (failure) {
      delayMs = this.#recordFailure()
      this.#publishRecovering(delayMs, failure)
    } else if (this.#status.kind === "connected") {
      this.#publish({ kind: "connecting" })
    }
    try {
      const connection = this.#connection
      this.#connection = undefined
      this.#state = "connecting"
      this.#flushingUpdates = false
      this.#rotationDue = false
      await connection?.close()
      this.#requireCurrent(generation)
      await this.events.send({ type: "connecting" })
      this.#requireCurrent(generation)
      if (delayMs > 0) {
        await this.#sleep(generation, delayMs)
        this.#requireCurrent(generation)
      }
      await this.#open(generation, Number.POSITIVE_INFINITY)
    } catch (error) {
      if (this.#generation !== generation || this.#isIdle()) return
      if (isSessionRevoked(error)) {
        await this.#authenticationInvalidated(generation, error)
        return
      }
      const persistenceFailed = typeof error === "object" && error !== null && this.#persistenceFailures.has(error)
      if ((this.#recoveringAuthorization || isAuthorizationInvalidated(error)) &&
          (persistenceFailed || !isTransientNetworkFailure(error))) {
        // Keep permanent authority, but require an explicit start after a refused replacement.
        this.#state = "idle"
        this.#failures = 0
        this.#log.warn?.("Inline Protocol temporary authorization replacement failed; automatic recovery stopped", error)
        this.#publish({
          kind: "offline",
          reason: persistenceFailed ? "credential-persistence-failed" : "authorization-rejected",
          error: asError(error),
        })
        return
      }
      const retryInMs = this.#recordFailure()
      this.#log.warn?.(`Inline Protocol reconnect failed; retrying in ${retryInMs}ms`, error)
      this.#retryTimer = setTimeout(() => {
        this.#retryTimer = undefined
        if (this.#generation !== generation || this.#state === "idle") return
        void this.#reconnect()
      }, retryInMs)
      this.#publishRecovering(retryInMs, asError(error))
    } finally {
      if (this.#reconnectingGeneration === generation) this.#reconnectingGeneration = undefined
      const closedDuringOpen = this.#reconnectAfterOpen
      if (this.#generation === generation && closedDuringOpen && !this.#isIdle()) {
        this.#reconnectAfterOpen = undefined
        void this.#reconnect(closedDuringOpen)
      }
    }
  }

  async send(message: ClientMessage): Promise<void> {
    const connection = this.#connection
    if (this.#state !== "connected" || !connection) throw TransportError.notConnected()
    if (this.#rotationDue) {
      this.#maybeRotate()
      throw TransportError.rejectedBeforeExecution(
        "Inline Protocol temporary authorization reached its rotation boundary before request admission",
      )
    }

    switch (message.body.oneofKind) {
      case "connectionInit":
        await this.events.send({
          type: "message",
          message: ServerProtocolMessage.create({
            id: message.id,
            body: { oneofKind: "connectionOpen", connectionOpen: {} },
          }),
        })
        return
      case "rpcCall": {
        this.#activeRequests += 1
        let response: Awaited<ReturnType<InlineProtocolV3Connection["invoke"]>>
        const generation = this.#generation
        const transfer = TRANSFER_RPC_METHODS.has(message.body.rpcCall.method)
          ? await this.#acquireTransfer(generation)
          : undefined
        try {
          const request = { body: { oneofKind: "rpc" as const, rpc: message.body.rpcCall } }
          const invokeOn = async (target: InlineProtocolV3Connection, current: () => boolean) => {
            for (let attempt = 0; ; attempt += 1) {
              try {
                return await target.invoke(request)
              } catch (error) {
                if (!(error instanceof InlineProtocolV3Error) || error.code !== "rejected-before-execution") {
                  throw error
                }
                if (attempt >= rejectedBeforeExecutionRetryLimit) {
                  throw TransportError.capacityExceeded(
                    "Inline Protocol application remained overloaded before execution",
                  )
                }
                await new Promise((resolve) => setTimeout(resolve, rejectedBeforeExecutionRetryDelayMs))
                if (!current()) {
                  throw TransportError.rejectedBeforeExecution(
                    "Inline Protocol connection changed before rejected work could be redelivered",
                  )
                }
              }
            }
          }
          const mainIsCurrent = () =>
            this.#state === "connected" && this.#connection === connection && !this.#rotationDue
          if (transfer) {
            try {
              response = await invokeOn(transfer, () => this.#transfer?.connection === transfer)
            } catch (error) {
              if (!transferCarrierFailed(error)) throw error
              // Transfer RPCs are idempotent; the main connection finishes this one.
              this.#log.warn?.("Inline Protocol transfer connection failed; using the main connection", error)
              this.#closeTransfer(transfer)
              response = await invokeOn(connection, mainIsCurrent)
            }
          } else {
            response = await invokeOn(connection, mainIsCurrent)
          }
        } catch (error) {
          if (error instanceof InlineProtocolV3Error && error.code === "commit-outcome-unknown") {
            throw TransportError.commitOutcomeUnknown(error.message)
          }
          if (error instanceof InlineProtocolV3Error && error.code === "capacity-exceeded") {
            throw TransportError.capacityExceeded(error.message)
          }
          throw error
        } finally {
          this.#activeRequests -= 1
          if (transfer) this.#releaseTransfer(transfer)
          this.#maybeRotate()
        }
        if (response.body.oneofKind === "rpcResult") {
          await this.events.send({
            type: "message",
            message: ServerProtocolMessage.create({
              body: {
                oneofKind: "rpcResult",
                rpcResult: { ...response.body.rpcResult, reqMsgId: message.id },
              },
            }),
          })
          return
        }
        if (response.body.oneofKind === "rpcError") {
          await this.events.send({
            type: "message",
            message: ServerProtocolMessage.create({
              body: {
                oneofKind: "rpcError",
                rpcError: { ...response.body.rpcError, reqMsgId: message.id },
              },
            }),
          })
          return
        }
        throw new Error("Unexpected Inline Protocol RPC response")
      }
      case "ping":
        this.#activeRequests += 1
        try {
          await connection.ping(message.body.ping.nonce)
        } finally {
          this.#activeRequests -= 1
          this.#maybeRotate()
        }
        await this.events.send({
          type: "message",
          message: ServerProtocolMessage.create({
            body: { oneofKind: "pong", pong: { nonce: message.body.ping.nonce } },
          }),
        })
        return
      case "ack":
      case undefined:
        return
    }
  }

  getDiagnostics() {
    return {
      kind: "inline-protocol-v3",
      state: this.#state,
      connected: this.#connection !== undefined,
      recoveringAuthorization: this.#state === "connecting" && this.#recoveringAuthorization,
      hasTemporaryAuthorization: this.#credentials.temporary !== undefined,
      phase: this.#status.kind,
      consecutiveFailures: this.#failures,
      offlineReason: this.#status.kind === "offline" ? this.#status.reason : null,
    }
  }

  /** The last lifecycle state published to onStateChange. */
  get transportState(): InlineProtocolV3TransportState {
    return this.#status
  }

  async #open(generation: number, recoveryAttemptLimit: number): Promise<void> {
    if (this.#generation !== generation || this.#state === "idle") {
      throw new Error("Inline Protocol connection attempt was superseded")
    }
    let connection: InlineProtocolV3Connection | undefined
    let openingCloseError: Error | undefined
    let cachedRejection: Error | undefined
    const temporary = this.#credentials.temporary
    if (temporary?.expiresAt !== undefined) {
      try {
        let cachedSource: InlineProtocolV3Connection | undefined
        connection = await InlineProtocolV3Connection.connect({
          url: this.#options.url,
          rsaPublicKeys: [],
          authorization: temporary,
          requestTimeoutMs: this.#options.requestTimeoutMs,
          onUpdate: (update) => {
            void this.#forwardUpdate(generation, update).catch((error) => {
              this.#connectionFailed(generation, error instanceof Error ? error : new Error(String(error)))
            })
          },
          onClose: (error) => {
            if (cachedSource && this.#connection === cachedSource) {
              this.#connectionFailed(generation, error)
            } else {
              openingCloseError ??= error
            }
          },
          // Let the authenticated message that crossed the boundary finish delivery first.
          onRotationDue: () => {
            setTimeout(() => {
              if (cachedSource) this.#rotationBecameDue(generation, cachedSource)
            }, 0)
          },
        })
        cachedSource = connection
        this.#requireCurrent(generation)
        await connection.probeTemporaryAuthorization()
        if (openingCloseError) throw openingCloseError
        this.#requireCurrent(generation)
        if (connection.temporaryAuthorizationNeedsRotation()) {
          this.#log.info?.("Stored Inline Protocol temporary authorization reached its rotation boundary")
          await connection.close()
          connection = undefined
          openingCloseError = undefined
        }
      } catch (error) {
        await connection?.close()
        connection = undefined
        if (!isAuthorizationInvalidated(error)) throw error
        this.#requireCurrent(generation)
        this.#credentials.temporary = undefined
        this.#recoveringAuthorization = true
        this.#log.warn?.("Stored Inline Protocol temporary authorization was rejected; starting recovery", error)
        openingCloseError = undefined
        cachedRejection = error
      }
    }

    if (!connection) {
      if (cachedRejection) {
        // Give a restarting server a moment, jittered across the fleet.
        const retryInMs = this.#recordFailure()
        this.#publishRecovering(retryInMs, cachedRejection)
        await this.#sleep(generation, retryInMs)
      }
      if (this.#generation !== generation || this.#isIdle()) {
        throw new Error("Inline Protocol connection attempt was superseded")
      }
      if (this.#options.rsaPublicKeys.length === 0) {
        throw new Error("Pinned Inline Protocol RSA keys are required to replace the temporary authorization")
      }
      for (let attempt = 0; !connection; attempt += 1) {
        this.#requireCurrent(generation)
        let replacement: InlineProtocolV3Connection | undefined
        let attemptCurrent = true
        openingCloseError = undefined
        try {
          replacement = await InlineProtocolV3Connection.connect({
            url: this.#options.url,
            rsaPublicKeys: this.#options.rsaPublicKeys,
            temporary: true,
            requestTimeoutMs: this.#options.requestTimeoutMs,
            onUpdate: (update) => {
              if (!attemptCurrent) return
              void this.#forwardUpdate(generation, update).catch((error) => {
                this.#connectionFailed(generation, error instanceof Error ? error : new Error(String(error)))
              })
            },
            onClose: (error) => {
              if (!attemptCurrent) return
              if (replacement && this.#connection === replacement) {
                this.#connectionFailed(generation, error)
              } else {
                openingCloseError ??= error
              }
            },
            // Let the authenticated message that crossed the boundary finish delivery first.
            onRotationDue: () => {
              setTimeout(() => {
                if (attemptCurrent && replacement) this.#rotationBecameDue(generation, replacement)
              }, 0)
            },
          })
          this.#requireCurrent(generation)
          await replacement.bindTemporary(this.#credentials.permanent)
          await replacement.ping()
          if (openingCloseError) throw openingCloseError
          this.#requireCurrent(generation)
          connection = replacement
        } catch (error) {
          attemptCurrent = false
          await replacement?.close()
          this.#requireCurrent(generation)
          if (!this.#recoveringAuthorization || !isTransientNetworkFailure(error) ||
              attempt + 1 >= recoveryAttemptLimit) throw error
          // No application request or persistence has started. A restart can lose
          // the new socket while establishing/binding/probing its temporary key.
          this.#pendingUpdates = []
          this.#pendingUpdateBytes = 0
          const retryInMs = this.#recordFailure()
          this.#log.warn?.(`Inline Protocol temporary authorization bootstrap interrupted; retrying in ${retryInMs}ms`, error)
          this.#publishRecovering(retryInMs, error)
          await this.#sleep(generation, retryInMs)
        }
      }
    }

    const nextCredentials = cloneCredentials(this.#credentials)
    nextCredentials.temporary = connection.authorization
    try {
      this.#requireCurrent(generation)
      try {
        await this.#options.onCredentials?.(cloneCredentials(nextCredentials))
      } catch (error) {
        // Classified by source, not code: a storage timeout is not a network failure.
        if (typeof error === "object" && error !== null) this.#persistenceFailures.add(error)
        throw error
      }
      if (openingCloseError) throw openingCloseError
      this.#requireCurrent(generation)
    } catch (error) {
      await connection.close()
      throw error
    }
    this.#recoveringAuthorization = false
    this.#failures = 0
    this.#credentials = nextCredentials
    this.#connection = connection
    this.#state = "connected"
    this.#publish({ kind: "connected" })
    this.#flushingUpdates = true
    await this.events.send({ type: "connected" })
    await this.#flushPendingUpdates(generation)
    this.#maybeRotate()
  }

  /**
   * A second connection with its own RAM-only temporary key, bound to the stored
   * permanent key and declared transfer-only, so file parts never queue behind
   * chat on the main socket. Returns undefined (use the main connection) when it
   * cannot be opened.
   */
  async #acquireTransfer(generation: number): Promise<InlineProtocolV3Connection | undefined> {
    if (this.#options.rsaPublicKeys.length === 0 || this.#state !== "connected") return undefined
    if (this.#transfer && this.#transfer.generation !== generation) this.#closeTransfer()
    let transfer = this.#transfer
    if (!transfer) {
      const opening = this.#openTransfer()
      transfer = { generation, opening, active: 0 }
      this.#transfer = transfer
    }
    transfer.active += 1
    if (transfer.idleTimer) clearTimeout(transfer.idleTimer)
    transfer.idleTimer = undefined
    try {
      const connection = await transfer.opening
      if (this.#transfer !== transfer || this.#generation !== generation) {
        transfer.active -= 1
        return undefined
      }
      transfer.connection = connection
      return connection
    } catch (error) {
      transfer.active -= 1
      if (this.#transfer === transfer) this.#transfer = undefined
      this.#log.warn?.("Inline Protocol transfer connection unavailable; using the main connection", error)
      return undefined
    }
  }

  async #openTransfer(): Promise<InlineProtocolV3Connection> {
    let source: InlineProtocolV3Connection | undefined
    const connection = await InlineProtocolV3Connection.connect({
      url: this.#options.url,
      rsaPublicKeys: this.#options.rsaPublicKeys,
      temporary: true,
      requestTimeoutMs: this.#options.requestTimeoutMs,
      onClose: () => {
        if (source && this.#transfer?.connection === source) this.#transfer = undefined
      },
    })
    source = connection
    try {
      await connection.bindTemporary(this.#credentials.permanent)
      const opened = await connection.invoke({
        body: { oneofKind: "connectionInit", connectionInit: { token: "", transferOnly: true } },
      })
      if (opened.body.oneofKind !== "connectionOpen") {
        throw new InlineProtocolV3Error("protocol", "Transfer connection was not accepted")
      }
      return connection
    } catch (error) {
      await connection.close()
      throw error
    }
  }

  #releaseTransfer(connection: InlineProtocolV3Connection): void {
    const transfer = this.#transfer
    if (!transfer || transfer.connection !== connection) return
    transfer.active = Math.max(0, transfer.active - 1)
    if (transfer.active > 0) return
    if (transfer.idleTimer) clearTimeout(transfer.idleTimer)
    transfer.idleTimer = setTimeout(() => {
      if (this.#transfer === transfer && transfer.active === 0) this.#closeTransfer()
    }, transferIdleTimeoutMs)
    transfer.idleTimer.unref?.()
  }

  #closeTransfer(only?: InlineProtocolV3Connection): void {
    const transfer = this.#transfer
    if (!transfer || (only && transfer.connection !== only)) return
    this.#transfer = undefined
    if (transfer.idleTimer) clearTimeout(transfer.idleTimer)
    void transfer.opening.then((connection) => connection.close(), () => {})
  }

  get hasTransferConnection(): boolean {
    return this.#transfer?.connection !== undefined
  }

  #rotationBecameDue(generation: number, source: InlineProtocolV3Connection): void {
    if (this.#generation !== generation || this.#connection !== source || this.#state === "idle") return
    this.#rotationDue = true
    this.#maybeRotate()
  }

  #maybeRotate(): void {
    if (!this.#rotationDue || this.#activeRequests !== 0 || this.#state !== "connected") return
    void this.reconnect({ skipDelay: true, cause: "v3-temporary-key-rotation" })
  }

  #requireCurrent(generation: number): void {
    if (this.#generation === generation && this.#state !== "idle") return
    throw new Error("Inline Protocol connection attempt was superseded")
  }

  #isIdle(): boolean { return this.#state === "idle" }

  #connectionFailed(generation: number, error: Error): void {
    if (this.#generation !== generation || this.#state === "idle") return
    if (isSessionRevoked(error)) {
      void this.#authenticationInvalidated(generation, error)
      return
    }
    if (isAuthorizationInvalidated(error)) {
      this.#credentials.temporary = undefined
      this.#recoveringAuthorization = true
    }
    this.#log.warn?.("Inline Protocol connection closed; reconnecting", error)
    // A close can arrive while #open is publishing buffered events. Do not lose
    // it to reconnect's single-flight guard; finish that generation, then reopen.
    if (this.#reconnectingGeneration === generation) {
      this.#state = "connecting"
      this.#reconnectAfterOpen = error
      return
    }
    void this.#reconnect(error)
  }

  #recordFailure(): number {
    this.#failures += 1
    const capMs = Math.min(reconnectMaxDelayMs, reconnectBaseDelayMs * 2 ** Math.min(this.#failures - 1, 16))
    const sample = (this.#options.random ?? Math.random)()
    const unit = Number.isFinite(sample) ? Math.min(Math.max(sample, 0), 1 - Number.EPSILON) : 0
    return Math.floor(unit * (capMs + 1))
  }

  #publishRecovering(retryInMs: number, error: Error): void {
    this.#publish({
      kind: "recovering",
      attempt: this.#failures,
      retryInMs,
      replacingAuthorization: this.#recoveringAuthorization,
      error,
    })
  }

  #publish(state: InlineProtocolV3TransportState): void {
    if (state.kind === this.#status.kind && state.kind !== "recovering") return
    this.#status = state
    const onStateChange = this.#options.onStateChange
    if (!onStateChange) return
    queueMicrotask(() => {
      try {
        onStateChange(state)
      } catch (error) {
        this.#log.warn?.("Inline Protocol transport state callback failed", error)
      }
    })
  }

  #sleep(generation: number, ms: number): Promise<void> {
    if (this.#generation !== generation || this.#isIdle()) return Promise.resolve()
    return new Promise((resolve) => {
      const sleep: Sleep = {
        timer: setTimeout(() => {
          this.#sleeps.delete(sleep)
          resolve()
        }, ms),
        resolve,
      }
      this.#sleeps.add(sleep)
    })
  }

  /** Supersedes in-flight work; its backoff waits end now and their owners see the new generation. */
  #nextGeneration(): number {
    for (const sleep of this.#sleeps) {
      clearTimeout(sleep.timer)
      sleep.resolve()
    }
    this.#sleeps.clear()
    return ++this.#generation
  }

  async #authenticationInvalidated(generation: number, error: Error): Promise<void> {
    if (this.#generation !== generation || this.#state === "idle") return
    this.#nextGeneration()
    this.#failures = 0
    this.#reconnectingGeneration = undefined
    if (this.#retryTimer) {
      clearTimeout(this.#retryTimer)
      this.#retryTimer = undefined
    }
    this.#state = "idle"
    this.#flushingUpdates = false
    this.#pendingUpdates = []
    this.#pendingUpdateBytes = 0
    this.#rotationDue = false
    this.#closeTransfer()
    const connection = this.#connection
    this.#connection = undefined
    const terminalGeneration = this.#generation
    await connection?.close()
    if (this.#generation !== terminalGeneration) return
    this.#log.warn?.("Inline Protocol session revocation confirmed; reconnect disabled", error)
    this.#publish({ kind: "offline", reason: "session-revoked", error })
    await this.events.send({
      type: "message",
      message: ServerProtocolMessage.create({
        body: {
          oneofKind: "connectionError",
          connectionError: { reason: ConnectionError_Reason.SESSION_REVOKED },
        },
      }),
    })
  }

  async #forwardUpdate(generation: number, update: RealtimeV3Update): Promise<void> {
    if (!update.message || this.#generation !== generation || this.#state === "idle") return
    if (this.#state === "connecting" || this.#flushingUpdates) {
      const updateBytes = RealtimeV3Update.toBinary(update).byteLength
      if (this.#pendingUpdates.length >= pendingUpdateCapacity ||
          this.#pendingUpdateBytes + updateBytes > pendingUpdateByteCapacity) {
        throw new Error(
          `Inline Protocol pending update buffer exceeded ${pendingUpdateCapacity} events or ${pendingUpdateByteCapacity} bytes`,
        )
      }
      this.#pendingUpdates.push(update)
      this.#pendingUpdateBytes += updateBytes
      return
    }
    await this.events.send({
      type: "message",
      message: ServerProtocolMessage.create({
        body: { oneofKind: "message", message: update.message },
      }),
    })
  }

  async #flushPendingUpdates(generation: number): Promise<void> {
    if (this.#generation !== generation || this.#state !== "connected") return
    while (this.#generation === generation && this.#state === "connected") {
      const pending = this.#pendingUpdates
      this.#pendingUpdates = []
      this.#pendingUpdateBytes = 0
      if (pending.length === 0) {
        this.#flushingUpdates = false
        return
      }
      for (const update of pending) {
        if (!update.message) continue
        await this.events.send({
          type: "message",
          message: ServerProtocolMessage.create({
            body: { oneofKind: "message", message: update.message },
          }),
        })
      }
    }
  }
}
