import {
  BotEvent,
  ClientMessage,
  ConnectionError_Reason,
  RpcError,
  RpcResult,
  UpdatesPayload,
  type ConnectionInit,
  ServerProtocolMessage,
} from "@inline-chat/protocol/core"
import type { Method, RpcCall } from "@inline-chat/protocol/core"
import { AsyncChannel } from "../utils/async-channel.js"
import { PingPongService } from "./ping-pong.js"
import { TransportError, type Transport } from "./transport.js"
import type { ClientEvent, ClientState } from "./types.js"
import type { InlineSdkLogger } from "../sdk/logger.js"
import {
  InlineSdkAuthenticationError,
  authenticationErrorFromConnectionReason,
} from "../sdk/errors.js"

export type ProtocolClientOptions = {
  transport: Transport
  getConnectionInit: () => ConnectionInit | null
  processUpdates?: (updates: UpdatesPayload) => void | Promise<void>
  logger?: InlineSdkLogger
  defaultRpcTimeoutMs?: number | null
  maxPendingRpcRequests?: number
}

export type RpcReconnectPolicy = "never-replay" | "replay-safe"

export type RpcCallOptions = {
  timeoutMs?: number | null
  reconnectPolicy?: RpcReconnectPolicy
  signal?: AbortSignal
}

type PendingRpcRequest = {
  message: ClientMessage
  resolve: (value: RpcResult["result"]) => void
  reject: (error: Error) => void
  timeout?: ReturnType<typeof setTimeout>
  removeAbortListener?: () => void
  timeoutMs: number | null
  reconnectPolicy: RpcReconnectPolicy
  attempted: boolean
  sending: boolean
}

const emptyRpcInput: RpcCall["input"] = { oneofKind: undefined }
const defaultRpcTimeoutMs = 30_000
const defaultMaxPendingRpcRequests = 64
const maximumQueuedEventBytes = 8 * 1024 * 1024

const clientEventByteLength = (event: ClientEvent): number => {
  switch (event.type) {
    case "updates":
      return UpdatesPayload.toBinary(event.updates).byteLength
    case "bot":
      return BotEvent.toBinary(event.bot).byteLength
    case "rpcResult":
      return RpcResult.toBinary({ reqMsgId: event.msgId, result: event.rpcResult }).byteLength
    case "rpcError":
      return RpcError.toBinary(event.rpcError).byteLength
    default:
      return 32
  }
}

const assertValidRpcMethod = (method: Method) => {
  if (typeof method !== "number" || !Number.isInteger(method) || method <= 0) {
    throw new ProtocolClientError("invalid-rpc-method", { message: `Invalid rpc method: ${String(method)}` })
  }
}

export class ProtocolClient {
  readonly events = new AsyncChannel<ClientEvent>(256, {
    capacityBytes: maximumQueuedEventBytes,
    byteLength: clientEventByteLength,
  })
  readonly transport: Transport
  readonly pingPong: PingPongService

  state: ClientState = "connecting"

  private readonly log: InlineSdkLogger
  private readonly getConnectionInit: () => ConnectionInit | null
  private readonly processUpdates?: (updates: UpdatesPayload) => void | Promise<void>
  private readonly defaultRpcTimeoutMs: number | null
  private readonly maxPendingRpcRequests: number

  private pendingRpcRequests = new Map<bigint, PendingRpcRequest>()

  private seq = 0
  private lastTimestamp = 0
  private sequence = 0
  private readonly epochSeconds = 1_735_689_600

  private connectionAttemptNo = 0
  private reconnectionTimer: ReturnType<typeof setTimeout> | null = null
  private authenticationTimeout: ReturnType<typeof setTimeout> | null = null
  private listenersStarted = false
  private lastConnectingAt: number | null = null
  private lastOpenAt: number | null = null
  private lastTransportMessageAt: number | null = null
  private lastFailureAt: number | null = null
  private lastFailureReason: string | null = null
  private terminalAuthenticationError: InlineSdkAuthenticationError | null = null

  constructor(options: ProtocolClientOptions) {
    this.transport = options.transport
    this.log = options.logger ?? {}
    this.getConnectionInit = options.getConnectionInit
    this.processUpdates = options.processUpdates
    this.defaultRpcTimeoutMs = normalizeRpcTimeoutMs(options.defaultRpcTimeoutMs, defaultRpcTimeoutMs)
    this.maxPendingRpcRequests = options.maxPendingRpcRequests ?? defaultMaxPendingRpcRequests
    if (!Number.isSafeInteger(this.maxPendingRpcRequests) || this.maxPendingRpcRequests <= 0) {
      throw new RangeError("maxPendingRpcRequests must be a positive safe integer")
    }

    this.pingPong = new PingPongService({ logger: this.log })
    this.pingPong.configure(this)

    this.startListeners()
  }

  async startTransport() {
    if (this.terminalAuthenticationError) throw this.terminalAuthenticationError
    await this.transport.start()
  }

  async stopTransport() {
    await this.transport.stop()
  }

  async sendPing(nonce: bigint) {
    const message = this.wrapMessage({
      oneofKind: "ping",
      ping: { nonce },
    })

    try {
      await this.transport.send(message)
    } catch (error) {
      this.log.error?.("Failed to send ping", error)
    }
  }

  async reconnect(options?: { skipDelay?: boolean; cause?: string }) {
    if (this.terminalAuthenticationError) throw this.terminalAuthenticationError
    await this.transport.reconnect({
      skipDelay: options?.skipDelay,
      cause: options?.cause ?? this.lastFailureReason ?? "protocol-reconnect",
    })
  }

  async sendRpc(method: Method, input: RpcCall["input"] = emptyRpcInput): Promise<bigint> {
    if (this.terminalAuthenticationError) throw this.terminalAuthenticationError
    this.ensureOpenForRpc()
    assertValidRpcMethod(method)
    const message = this.wrapMessage({
      oneofKind: "rpcCall",
      rpcCall: { method, input },
    })

    await this.transport.send(message)
    return message.id
  }

  async callRpc(
    method: Method,
    input: RpcCall["input"] = emptyRpcInput,
    options?: RpcCallOptions,
  ): Promise<RpcResult["result"]> {
    if (this.terminalAuthenticationError) throw this.terminalAuthenticationError
    options?.signal?.throwIfAborted()
    assertValidRpcMethod(method)
    if (this.pendingRpcRequests.size >= this.maxPendingRpcRequests) {
      throw new ProtocolClientError("capacity-exceeded", {
        message: `Realtime RPC capacity ${this.maxPendingRpcRequests} exceeded`,
      })
    }
    const message = this.wrapMessage({
      oneofKind: "rpcCall",
      rpcCall: { method, input },
    })

    return await new Promise<RpcResult["result"]>((resolve, reject) => {
      const pending: PendingRpcRequest = {
        message,
        resolve,
        reject,
        timeoutMs: this.resolveRpcTimeoutMs(options?.timeoutMs),
        reconnectPolicy: options?.reconnectPolicy ?? "never-replay",
        attempted: false,
        sending: false,
      }

      this.pendingRpcRequests.set(message.id, pending)

      const onAbort = () => {
        const reason = options?.signal?.reason
        this.failPendingRpcRequest(
          message.id,
          reason instanceof Error ? reason : new DOMException("The operation was aborted", "AbortError"),
        )
      }
      options?.signal?.addEventListener("abort", onAbort, { once: true })
      pending.removeAbortListener = () => options?.signal?.removeEventListener("abort", onAbort)
      if (options?.signal?.aborted) onAbort()

      if (pending.timeoutMs !== null) {
        pending.timeout = setTimeout(() => {
          this.failPendingRpcRequest(
            message.id,
            pending.attempted && pending.reconnectPolicy === "never-replay"
              ? commitOutcomeUnknownError("RPC timed out after dispatch")
              : new ProtocolClientError("timeout"),
          )
        }, pending.timeoutMs)
      }

      this.trySendPendingRpcRequest(message.id)
    })
  }

  private async startListeners() {
    if (this.listenersStarted) return
    this.listenersStarted = true

    ;(async () => {
      for await (const event of this.transport.events) {
        switch (event.type) {
          case "connected":
            await this.authenticate()
            break
          case "message":
            await this.handleTransportMessage(event.message)
            break
          case "connecting":
            await this.connecting()
            break
          case "stopping":
            await this.reset()
            break
        }
      }
    })().catch(async (error) => {
      const failure = error instanceof Error ? error : new Error(String(error))
      this.log.error?.("Protocol client listener crashed", failure)
      this.events.fail(failure)
      await this.transport.stop().catch((stopError) => {
        this.log.warn?.("Protocol transport stop after listener failure failed", stopError)
      })
    })
  }

  private async handleTransportMessage(message: ServerProtocolMessage) {
    this.lastTransportMessageAt = Date.now()
    switch (message.body.oneofKind) {
      case "connectionOpen":
        await this.connectionOpen()
        break
      case "rpcResult":
        this.completeRpcResult(message.body.rpcResult.reqMsgId, message.body.rpcResult.result)
        await this.events.send({
          type: "rpcResult",
          msgId: message.body.rpcResult.reqMsgId,
          rpcResult: message.body.rpcResult.result,
        })
        break
      case "rpcError":
        this.completeRpcError(message.body.rpcError.reqMsgId, message.body.rpcError)
        await this.events.send({
          type: "rpcError",
          msgId: message.body.rpcError.reqMsgId,
          rpcError: message.body.rpcError,
        })
        break
      case "ack":
        await this.events.send({ type: "ack", msgId: message.body.ack.msgId })
        break
      case "message":
        if (message.body.message.payload.oneofKind === "update") {
          await this.processUpdates?.(message.body.message.payload.update)
          await this.events.send({ type: "updates", updates: message.body.message.payload.update })
        } else if (message.body.message.payload.oneofKind === "bot") {
          await this.events.send({ type: "bot", bot: message.body.message.payload.bot })
        }
        break
      case "pong":
        this.pingPong.pong(message.body.pong.nonce)
        break
      case "connectionError":
        const authenticationError = authenticationErrorFromConnectionReason(
          message.body.connectionError.reason,
        )
        if (authenticationError) {
          await this.handleTerminalAuthenticationFailure(authenticationError)
        } else {
          this.handleClientFailure(describeConnectionError(message.body.connectionError))
        }
        break
      default:
        break
    }
  }

  private async sendConnectionInit() {
    const connectionInit = this.getConnectionInit()
    if (!connectionInit) throw new ProtocolClientError("not-authorized")

    const message = this.wrapMessage({
      oneofKind: "connectionInit",
      connectionInit,
    })

    await this.transport.send(message)
  }

  private async authenticate() {
    if (this.terminalAuthenticationError) return
    try {
      await this.sendConnectionInit()
      this.startAuthenticationTimeout()
    } catch (error) {
      this.log.error?.("Failed to authenticate", error)
      this.handleClientFailure(`authenticate failed: ${summarizeError(error)}`)
    }
  }

  private async connectionOpen() {
    if (this.terminalAuthenticationError) return
    this.state = "open"
    this.lastOpenAt = Date.now()
    await this.events.send({ type: "open" })
    this.stopAuthenticationTimeout()
    if (this.reconnectionTimer) {
      clearTimeout(this.reconnectionTimer)
      this.reconnectionTimer = null
    }
    this.connectionAttemptNo = 0
    this.pingPong.start()
    this.resendPendingRpcRequests()
  }

  private async connecting() {
    if (this.terminalAuthenticationError) return
    this.pingPong.stop()
    this.state = "connecting"
    this.lastConnectingAt = Date.now()
    this.failAttemptedNonReplayableRequests("Connection changed before the RPC result arrived")
    await this.events.send({ type: "connecting" })
  }

  private async reset() {
    this.pingPong.stop()
    this.stopAuthenticationTimeout()
    if (this.reconnectionTimer) {
      clearTimeout(this.reconnectionTimer)
      this.reconnectionTimer = null
    }
    this.cancelAllPendingRpcRequests(new ProtocolClientError("stopped"))
    this.state = "connecting"
  }

  private startAuthenticationTimeout() {
    this.stopAuthenticationTimeout()
    this.authenticationTimeout = setTimeout(() => {
      if (this.state === "open" || this.terminalAuthenticationError) return
      this.handleClientFailure("authentication timeout after 10000ms")
    }, 10_000)
  }

  private stopAuthenticationTimeout() {
    if (!this.authenticationTimeout) return
    clearTimeout(this.authenticationTimeout)
    this.authenticationTimeout = null
  }

  private handleClientFailure(reason = "connection failure") {
    if (this.terminalAuthenticationError) return
    this.pingPong.stop()
    this.stopAuthenticationTimeout()
    this.state = "connecting"
    this.lastFailureAt = Date.now()
    this.lastFailureReason = reason
    this.failAttemptedNonReplayableRequests(`Connection failed before the RPC result arrived: ${reason}`)

    if (this.reconnectionTimer) {
      clearTimeout(this.reconnectionTimer)
    }

    this.connectionAttemptNo = (this.connectionAttemptNo + 1) >>> 0
    const delayMs = Math.round(this.getReconnectionDelay() * 1000)
    this.log.warn?.(
      `Protocol reconnect scheduled (attempt=${this.connectionAttemptNo}, delayMs=${delayMs}, reason=${reason})`,
    )
    this.reconnectionTimer = setTimeout(() => {
      if (this.state === "open" || this.terminalAuthenticationError) return
      void this.reconnect({ skipDelay: true })
    }, delayMs)
  }

  private async handleTerminalAuthenticationFailure(
    error: InlineSdkAuthenticationError,
  ) {
    if (this.terminalAuthenticationError) return
    this.terminalAuthenticationError = error
    this.pingPong.stop()
    this.stopAuthenticationTimeout()
    this.state = "connecting"
    this.lastFailureAt = Date.now()
    this.lastFailureReason = error.message

    if (this.reconnectionTimer) {
      clearTimeout(this.reconnectionTimer)
      this.reconnectionTimer = null
    }

    this.cancelAllPendingRpcRequests(error)
    this.log.warn?.(`Terminal authentication failure; reconnect disabled (${error.code})`)
    await this.events.send({ type: "authenticationError", error })
    await this.transport.stop()
  }

  private getReconnectionDelay() {
    const attemptNo = this.connectionAttemptNo
    if (attemptNo >= 8) return 8.0 + Math.random() * 5.0
    return Math.min(8.0, 0.2 + Math.pow(attemptNo, 1.5) * 0.4)
  }

  private wrapMessage(body: ClientMessage["body"]): ClientMessage {
    this.advanceSeq()
    return ClientMessage.create({
      id: this.generateId(),
      seq: this.seq,
      body,
    })
  }

  private advanceSeq() {
    this.seq = (this.seq + 1) >>> 0
  }

  private generateId(): bigint {
    // Message identifiers remain unique across reconnects and local clock rollback.
    // A late result from an older transport generation must never match a new RPC.
    const timestamp = Math.max(this.currentTimestamp(), this.lastTimestamp)
    if (timestamp === this.lastTimestamp) {
      this.sequence = (this.sequence + 1) >>> 0
    } else {
      this.sequence = 0
      this.lastTimestamp = timestamp
    }
    return (BigInt(timestamp) << 32n) | BigInt(this.sequence)
  }

  private currentTimestamp() {
    return Math.floor(Date.now() / 1000) - this.epochSeconds
  }

  private completeRpcResult(msgId: bigint, rpcResult: RpcResult["result"]) {
    const pending = this.getAndRemovePendingRpcRequest(msgId)
    pending?.resolve(rpcResult)
  }

  private ensureOpenForRpc() {
    if (this.state !== "open") {
      throw new ProtocolClientError("not-connected")
    }
  }

  private completeRpcError(msgId: bigint, rpcError: RpcError) {
    const error = new ProtocolClientError("rpc-error", { code: rpcError.code, message: rpcError.message })
    const pending = this.getAndRemovePendingRpcRequest(msgId)
    pending?.reject(error)
  }

  private failPendingRpcRequest(msgId: bigint, error: Error) {
    const pending = this.getAndRemovePendingRpcRequest(msgId)
    pending?.reject(error)
  }

  private getAndRemovePendingRpcRequest(msgId: bigint) {
    const pending = this.pendingRpcRequests.get(msgId)
    if (!pending) return null
    if (pending.timeout) clearTimeout(pending.timeout)
    pending.removeAbortListener?.()
    this.pendingRpcRequests.delete(msgId)
    return pending
  }

  private cancelAllPendingRpcRequests(error: Error) {
    for (const pending of this.pendingRpcRequests.values()) {
      pending.reject(error)
      if (pending.timeout) clearTimeout(pending.timeout)
      pending.removeAbortListener?.()
    }
    this.pendingRpcRequests.clear()
  }

  private resolveRpcTimeoutMs(timeoutMs: number | null | undefined): number | null {
    return normalizeRpcTimeoutMs(timeoutMs, this.defaultRpcTimeoutMs)
  }

  private resendPendingRpcRequests() {
    for (const msgId of this.pendingRpcRequests.keys()) {
      const pending = this.pendingRpcRequests.get(msgId)
      if (pending?.attempted && pending.reconnectPolicy === "never-replay") {
        this.failPendingRpcRequest(
          msgId,
          commitOutcomeUnknownError("Connection reopened before the RPC result arrived"),
        )
        continue
      }
      this.trySendPendingRpcRequest(msgId)
    }
  }

  private trySendPendingRpcRequest(msgId: bigint) {
    const pending = this.pendingRpcRequests.get(msgId)
    if (!pending) return
    if (this.state !== "open") return
    if (pending.sending) return

    pending.attempted = true
    pending.sending = true
    void this.transport
      .send(pending.message)
      .catch((error) => {
        const current = this.pendingRpcRequests.get(msgId)
        if (error instanceof TransportError && error.code === "rejected-before-execution") {
          if (current) {
            current.attempted = false
            current.sending = false
          }
          this.log.warn?.("RPC was rejected before transport admission; waiting for reconnect", error)
          this.handleClientFailure(`rpc rejected before execution: ${summarizeError(error)}`)
          return
        }
        if (error instanceof TransportError && error.code === "commit-outcome-unknown") {
          this.failPendingRpcRequest(msgId, commitOutcomeUnknownError(error.message))
          return
        }
        if (error instanceof TransportError && error.code === "capacity-exceeded") {
          this.failPendingRpcRequest(msgId, new ProtocolClientError("capacity-exceeded", { message: error.message }))
          return
        }
        if (current?.reconnectPolicy === "never-replay") {
          this.failPendingRpcRequest(
            msgId,
            commitOutcomeUnknownError(`RPC transport failed after dispatch: ${summarizeError(error)}`),
          )
        }
        this.log.warn?.(
          current?.reconnectPolicy === "replay-safe"
            ? "Failed to send replay-safe RPC request; waiting for reconnect"
            : "Failed to send non-replayable RPC request; commit outcome is unknown",
          error,
        )
        this.handleClientFailure(`rpc send failed: ${summarizeError(error)}`)
      })
      .finally(() => {
        pending.sending = false
      })
  }

  private failAttemptedNonReplayableRequests(reason: string) {
    for (const [msgId, pending] of this.pendingRpcRequests) {
      if (!pending.attempted || pending.reconnectPolicy !== "never-replay") continue
      this.failPendingRpcRequest(msgId, commitOutcomeUnknownError(reason))
    }
  }

  getDiagnostics() {
    return {
      state: this.state,
      connectionAttemptNo: this.connectionAttemptNo,
      pendingRpcCount: this.pendingRpcRequests.size,
      maxPendingRpcRequests: this.maxPendingRpcRequests,
      lastConnectingAt: this.lastConnectingAt,
      lastOpenAt: this.lastOpenAt,
      lastTransportMessageAt: this.lastTransportMessageAt,
      lastFailureAt: this.lastFailureAt,
      lastFailureReason: this.lastFailureReason,
      terminalAuthenticationErrorCode: this.terminalAuthenticationError?.code ?? null,
      ping: this.pingPong.getDiagnostics(),
      transport:
        typeof this.transport.getDiagnostics === "function" ? this.transport.getDiagnostics() : null,
    }
  }
}

const normalizeRpcTimeoutMs = (timeoutMs: number | null | undefined, fallback: number | null): number | null => {
  const resolved = timeoutMs === undefined ? fallback : timeoutMs
  if (resolved == null) return null
  if (resolved === Number.POSITIVE_INFINITY) return null
  if (!Number.isFinite(resolved)) return null
  if (resolved <= 0) return null
  return Math.floor(resolved)
}

export class ProtocolClientError extends Error {
  constructor(
    readonly code:
      | "not-authorized"
      | "not-connected"
      | "rpc-error"
      | "stopped"
      | "timeout"
      | "commit-outcome-unknown"
      | "capacity-exceeded"
      | "invalid-rpc-method",
    details?: { code?: number; message?: string },
  ) {
    super(details?.message ?? code)
    this.name = `ProtocolClientError:${code}`
  }
}

const commitOutcomeUnknownError = (message: string) =>
  new ProtocolClientError("commit-outcome-unknown", { message })

function summarizeError(error: unknown): string {
  if (error instanceof Error) {
    return `${error.name}: ${error.message}`
  }
  return String(error)
}

function describeConnectionError(error: unknown): string {
  const value = typeof error === "object" && error !== null ? (error as Record<string, unknown>) : null
  const reason = typeof value?.reason === "number" ? value.reason : null
  const reasonName = reason == null ? null : (ConnectionError_Reason[reason] ?? `UNKNOWN_REASON_${reason}`)
  const code = typeof value?.code === "number" ? value.code : null
  const message = typeof value?.message === "string" && value.message.trim() ? value.message.trim() : (reasonName ?? "unknown")
  const suffix = reasonName != null ? ` (${reasonName})` : (code != null ? ` (code=${code})` : "")
  return `server connection error${suffix}: ${message}`
}
