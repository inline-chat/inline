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

type State = "idle" | "connecting" | "connected"
const pendingUpdateCapacity = 256
const pendingUpdateByteCapacity = 8 * 1024 * 1024
const transportEventByteCapacity = 8 * 1024 * 1024
const rejectedBeforeExecutionRetryLimit = 2
const rejectedBeforeExecutionRetryDelayMs = 1_000

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

const isAuthenticationInvalidated = (error: unknown): error is InlineProtocolV3Error =>
  error instanceof InlineProtocolV3Error && error.code === "unauthorized"

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
  #reconnecting = false
  #generation = 0
  #retryTimer: ReturnType<typeof setTimeout> | undefined
  #pendingUpdates: RealtimeV3Update[] = []
  #pendingUpdateBytes = 0
  #flushingUpdates = false
  #rotationDue = false
  #activeRequests = 0

  constructor(options: InlineProtocolV3TransportOptions) {
    this.#options = options
    this.#log = options.logger ?? {}
    this.#credentials = cloneCredentials(options.credentials)
  }

  async start(): Promise<void> {
    if (this.#state !== "idle") return
    this.#state = "connecting"
    this.#flushingUpdates = false
    this.#rotationDue = false
    const generation = ++this.#generation
    this.#pendingUpdates = []
    this.#pendingUpdateBytes = 0
    await this.events.send({ type: "connecting" })
    try {
      await this.#open(generation)
    } catch (error) {
      if (isAuthenticationInvalidated(error)) {
        await this.#authenticationInvalidated(generation, error)
        return
      }
      if (this.#generation === generation) this.#state = "idle"
      throw error
    }
  }

  async stop(): Promise<void> {
    ++this.#generation
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
    await connection?.close()
  }

  async stopConnection(): Promise<void> {
    ++this.#generation
    const connection = this.#connection
    this.#connection = undefined
    if (this.#state !== "idle") this.#state = "connecting"
    await connection?.close()
  }

  async reconnect(options?: TransportReconnectOptions): Promise<void> {
    if (this.#state === "idle" || this.#reconnecting) return
    this.#reconnecting = true
    if (this.#retryTimer) {
      clearTimeout(this.#retryTimer)
      this.#retryTimer = undefined
    }
    const generation = ++this.#generation
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
      if (isAuthenticationInvalidated(error)) {
        await this.#authenticationInvalidated(generation, error)
        return
      }
      this.#log.warn?.("Inline Protocol reconnect failed", error)
      this.#retryTimer = setTimeout(() => {
        this.#retryTimer = undefined
        if (this.#generation !== generation || this.#state === "idle") return
        void this.reconnect({ cause: "v3-retry" })
      }, options?.skipDelay ? 0 : 1_000)
    } finally {
      this.#reconnecting = false
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
        try {
          const request = { body: { oneofKind: "rpc" as const, rpc: message.body.rpcCall } }
          for (let attempt = 0; ; attempt += 1) {
            try {
              response = await connection.invoke(request)
              break
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
              if (this.#state !== "connected" || this.#connection !== connection || this.#rotationDue) {
                throw TransportError.rejectedBeforeExecution(
                  "Inline Protocol connection changed before rejected work could be redelivered",
                )
              }
            }
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
      hasTemporaryAuthorization: this.#credentials.temporary !== undefined,
    }
  }

  async #open(generation: number): Promise<void> {
    if (this.#generation !== generation || this.#state === "idle") {
      throw new Error("Inline Protocol connection attempt was superseded")
    }
    let connection: InlineProtocolV3Connection | undefined
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
          onClose: (error) => this.#connectionFailed(generation, error),
          // Let the authenticated message that crossed the boundary finish delivery first.
          onRotationDue: () => {
            setTimeout(() => {
              if (cachedSource) this.#rotationBecameDue(generation, cachedSource)
            }, 0)
          },
        })
        cachedSource = connection
        await connection.probeTemporaryAuthorization()
        this.#requireCurrent(generation)
        if (connection.temporaryAuthorizationNeedsRotation()) {
          this.#log.info?.("Stored Inline Protocol temporary authorization reached its rotation boundary")
          await connection.close()
          connection = undefined
        }
      } catch (error) {
        await connection?.close()
        connection = undefined
        if (!isAuthenticationInvalidated(error)) throw error
        this.#log.warn?.("Stored Inline Protocol temporary authorization was rejected; regenerating once", error)
      }
    }

    if (!connection) {
      if (this.#generation !== generation || this.#isIdle()) {
        throw new Error("Inline Protocol connection attempt was superseded")
      }
      if (this.#options.rsaPublicKeys.length === 0) {
        throw new Error("Pinned Inline Protocol RSA keys are required to replace the temporary authorization")
      }
      let replacementSource: InlineProtocolV3Connection | undefined
      const replacement = await InlineProtocolV3Connection.connect({
        url: this.#options.url,
        rsaPublicKeys: this.#options.rsaPublicKeys,
        temporary: true,
        requestTimeoutMs: this.#options.requestTimeoutMs,
        onUpdate: (update) => {
          void this.#forwardUpdate(generation, update).catch((error) => {
            this.#connectionFailed(generation, error instanceof Error ? error : new Error(String(error)))
          })
        },
        onClose: (error) => this.#connectionFailed(generation, error),
        // Let the authenticated message that crossed the boundary finish delivery first.
        onRotationDue: () => {
          setTimeout(() => {
            if (replacementSource) this.#rotationBecameDue(generation, replacementSource)
          }, 0)
        },
      })
      replacementSource = replacement
      try {
        await replacement.bindTemporary(this.#credentials.permanent)
        await replacement.ping()
        this.#requireCurrent(generation)
        connection = replacement
      } catch (error) {
        await replacement.close()
        throw error
      }
    }

    const nextCredentials = cloneCredentials(this.#credentials)
    nextCredentials.temporary = connection.authorization
    try {
      await this.#options.onCredentials?.(cloneCredentials(nextCredentials))
      this.#requireCurrent(generation)
    } catch (error) {
      await connection.close()
      throw error
    }
    this.#credentials = nextCredentials
    this.#connection = connection
    this.#state = "connected"
    this.#flushingUpdates = true
    await this.events.send({ type: "connected" })
    await this.#flushPendingUpdates(generation)
    this.#maybeRotate()
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
    if (isAuthenticationInvalidated(error)) {
      void this.#authenticationInvalidated(generation, error)
      return
    }
    this.#log.warn?.("Inline Protocol connection closed; reconnecting", error)
    void this.reconnect({ skipDelay: true, cause: "v3-connection-closed" })
  }

  async #authenticationInvalidated(generation: number, error: Error): Promise<void> {
    if (this.#generation !== generation || this.#state === "idle") return
    ++this.#generation
    if (this.#retryTimer) {
      clearTimeout(this.#retryTimer)
      this.#retryTimer = undefined
    }
    this.#state = "idle"
    this.#flushingUpdates = false
    this.#pendingUpdates = []
    this.#pendingUpdateBytes = 0
    this.#rotationDue = false
    const connection = this.#connection
    this.#connection = undefined
    await connection?.close()
    this.#log.warn?.("Inline Protocol authorization invalidated; reconnect disabled", error)
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
