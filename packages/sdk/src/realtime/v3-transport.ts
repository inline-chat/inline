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
const authorizationRecoveryDelayMs = 1_000
const authorizationRecoveryAttemptLimit = 3
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

export type InlineProtocolV3TransportOptions = {
  url: string
  rsaPublicKeys: readonly InlineProtocolPublicKey[]
  credentials: InlineProtocolV3Credentials
  requestTimeoutMs?: number
  logger?: InlineSdkLogger
  onCredentials?: (credentials: InlineProtocolV3Credentials) => void | Promise<void>
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
  #reconnectAfterOpen = false
  #generation = 0
  #retryTimer: ReturnType<typeof setTimeout> | undefined
  #pendingUpdates: RealtimeV3Update[] = []
  #pendingUpdateBytes = 0
  #flushingUpdates = false
  #rotationDue = false
  #activeRequests = 0
  #transfer: TransferConnection | undefined
  // One bounded replacement episode per invalidation; only transient bootstrap failures retry.
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
    this.#reconnectAfterOpen = false
    this.#flushingUpdates = false
    this.#rotationDue = false
    const generation = ++this.#generation
    this.#pendingUpdates = []
    this.#pendingUpdateBytes = 0
    await this.events.send({ type: "connecting" })
    try {
      await this.#open(generation)
    } catch (error) {
      if (isSessionRevoked(error)) {
        await this.#authenticationInvalidated(generation, error)
        return
      }
      if (this.#generation === generation) this.#state = "idle"
      throw error
    }
  }

  async stop(): Promise<void> {
    ++this.#generation
    this.#reconnectingGeneration = undefined
    if (this.#retryTimer) {
      clearTimeout(this.#retryTimer)
      this.#retryTimer = undefined
    }
    if (this.#state === "idle" && !this.#connection) return
    this.#state = "idle"
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
    ++this.#generation
    this.#reconnectingGeneration = undefined
    const connection = this.#connection
    this.#connection = undefined
    if (this.#state !== "idle") this.#state = "connecting"
    this.#closeTransfer()
    await connection?.close()
  }

  async reconnect(options?: TransportReconnectOptions): Promise<void> {
    if (this.#state === "idle" || this.#reconnectingGeneration !== undefined) return
    this.#reconnectAfterOpen = false
    if (this.#retryTimer) {
      clearTimeout(this.#retryTimer)
      this.#retryTimer = undefined
    }
    const generation = ++this.#generation
    this.#reconnectingGeneration = generation
    this.#pendingUpdates = []
    this.#pendingUpdateBytes = 0
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
      await this.#open(generation)
    } catch (error) {
      if (this.#generation !== generation || this.#isIdle()) return
      if (isSessionRevoked(error)) {
        await this.#authenticationInvalidated(generation, error)
        return
      }
      if (this.#recoveringAuthorization || isAuthorizationInvalidated(error)) {
        // Keep permanent authority, but require an explicit start after a failed replacement.
        this.#state = "idle"
        this.#log.warn?.("Inline Protocol temporary authorization replacement failed; automatic recovery stopped", error)
        return
      }
      this.#log.warn?.("Inline Protocol reconnect failed", error)
      this.#retryTimer = setTimeout(() => {
        this.#retryTimer = undefined
        if (this.#generation !== generation || this.#state === "idle") return
        void this.reconnect({ cause: "v3-retry" })
      }, options?.skipDelay ? 0 : 1_000)
    } finally {
      if (this.#reconnectingGeneration === generation) this.#reconnectingGeneration = undefined
      if (this.#generation === generation && this.#reconnectAfterOpen && !this.#isIdle()) {
        this.#reconnectAfterOpen = false
        void this.reconnect({ cause: "v3-closed-during-open" })
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
    }
  }

  async #open(generation: number): Promise<void> {
    if (this.#generation !== generation || this.#state === "idle") {
      throw new Error("Inline Protocol connection attempt was superseded")
    }
    let connection: InlineProtocolV3Connection | undefined
    let openingCloseError: Error | undefined
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
        this.#log.warn?.("Stored Inline Protocol temporary authorization was rejected; starting bounded recovery", error)
        openingCloseError = undefined
      }
    }

    if (!connection) {
      if (this.#recoveringAuthorization) {
        await new Promise((resolve) => setTimeout(resolve, authorizationRecoveryDelayMs))
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
          const transient = error instanceof InlineProtocolV3Error && (error.code === "closed" || error.code === "timeout")
          if (!this.#recoveringAuthorization || !transient || attempt + 1 >= authorizationRecoveryAttemptLimit) throw error
          // No application request or persistence has started. A restart can lose
          // the new socket while establishing/binding/probing its temporary key.
          this.#pendingUpdates = []
          this.#pendingUpdateBytes = 0
          this.#log.warn?.("Inline Protocol temporary authorization bootstrap interrupted; retrying", error)
          await new Promise((resolve) => setTimeout(resolve, authorizationRecoveryDelayMs * (attempt + 1)))
        }
      }
    }

    const nextCredentials = cloneCredentials(this.#credentials)
    nextCredentials.temporary = connection.authorization
    try {
      this.#requireCurrent(generation)
      await this.#options.onCredentials?.(cloneCredentials(nextCredentials))
      if (openingCloseError) throw openingCloseError
      this.#requireCurrent(generation)
    } catch (error) {
      await connection.close()
      throw error
    }
    this.#recoveringAuthorization = false
    this.#credentials = nextCredentials
    this.#connection = connection
    this.#state = "connected"
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
      this.#reconnectAfterOpen = true
      return
    }
    void this.reconnect({ skipDelay: true, cause: "v3-connection-closed" })
  }

  async #authenticationInvalidated(generation: number, error: Error): Promise<void> {
    if (this.#generation !== generation || this.#state === "idle") return
    ++this.#generation
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
