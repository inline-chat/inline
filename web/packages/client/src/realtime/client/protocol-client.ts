import { ClientMessage, ConnectionInit, ServerProtocolMessage } from "@inline-chat/protocol/core"
import type { Method, RpcCall, RpcError, RpcResult } from "@inline-chat/protocol/core"
import { Log, type LogLevel } from "@inline/log"
import { AsyncChannel } from "../../utils/async-channel"
import { PingPongService } from "./ping-pong"
import type { Transport } from "../transport/transport"
import type { ClientEvent, ClientState } from "../types"

export type ProtocolClientOptions = {
  transport: Transport
  getConnectionInit: () => ConnectionInit | null
  logLevel?: LogLevel
  logger?: Log
}

type RpcContinuation = {
  resolve: (value: RpcResult["result"]) => void
  reject: (error: Error) => void
  timeout?: ReturnType<typeof setTimeout>
}

const emptyRpcInput: RpcCall["input"] = { oneofKind: undefined }

export class ProtocolClient {
  readonly events = new AsyncChannel<ClientEvent>()
  readonly transport: Transport
  readonly pingPong: PingPongService

  state: ClientState = "connecting"

  private readonly log: Log
  private readonly getConnectionInit: () => ConnectionInit | null

  private rpcContinuations = new Map<bigint, RpcContinuation>()

  private seq = 0
  private lastTimestamp = 0
  private sequence = 0
  private readonly epochSeconds = 1_735_689_600

  private connectionAttemptNo = 0
  private reconnectionTimer: ReturnType<typeof setTimeout> | null = null
  private authenticationTimeout: ReturnType<typeof setTimeout> | null = null
  private listenersStarted = false

  constructor(options: ProtocolClientOptions) {
    const baseLogger = options.logger ?? new Log("RealtimeV2.ProtocolClient", options.logLevel)

    this.transport = options.transport
    this.log = baseLogger
    this.getConnectionInit = options.getConnectionInit

    this.pingPong = new PingPongService(baseLogger.withScope("PingPongService"))
    this.pingPong.configure(this)

    this.startListeners()
  }

  async startTransport() {
    await this.transport.start()
  }

  async stopTransport() {
    await this.transport.stop()
  }

  async sendPing(nonce: bigint) {
    const message = this.wrapMessage({
      oneofKind: "ping",
      ping: {
        nonce,
      },
    })

    try {
      await this.transport.send(message)
    } catch (error) {
      this.log.error("Failed to send ping", error)
    }
  }

  async reconnect(options?: { skipDelay?: boolean }) {
    this.log.trace("Reconnecting transport")
    await this.transport.reconnect({ skipDelay: options?.skipDelay })
  }

  async sendRpc(method: Method, input: RpcCall["input"] = emptyRpcInput): Promise<bigint> {
    const message = this.wrapMessage({
      oneofKind: "rpcCall",
      rpcCall: {
        method,
        input,
      },
    })

    await this.transport.send(message)
    return message.id
  }

  async callRpc(
    method: Method,
    input: RpcCall["input"] = emptyRpcInput,
    options?: { timeoutMs?: number },
  ): Promise<RpcResult["result"]> {
    const message = this.wrapMessage({
      oneofKind: "rpcCall",
      rpcCall: {
        method,
        input,
      },
    })

    return await new Promise<RpcResult["result"]>((resolve, reject) => {
      const continuation: RpcContinuation = { resolve, reject }
      this.rpcContinuations.set(message.id, continuation)

      void this.transport.send(message).catch((error) => {
        this.failRpcContinuation(message.id, error)
      })

      const timeoutMs = options?.timeoutMs ?? 15_000
      if (timeoutMs > 0) {
        continuation.timeout = setTimeout(() => {
          if (!this.rpcContinuations.has(message.id)) return
          this.failRpcContinuation(message.id, new ProtocolClientError("timeout"))
        }, timeoutMs)
      }
    })
  }

  private async startListeners() {
    if (this.listenersStarted) return
    this.listenersStarted = true

    ;(async () => {
      for await (const event of this.transport.events) {
        switch (event.type) {
          case "connected":
            this.log.trace("Protocol client: Transport connected")
            await this.authenticate()
            break

          case "message":
            this.log.trace("Protocol client received transport message", event.message)
            await this.handleTransportMessage(event.message)
            break

          case "connecting":
            await this.connecting()
            break

          case "stopping":
            this.log.trace("Protocol client: Transport stopping. Resetting state")
            await this.reset()
            break
        }
      }
    })().catch((error) => {
      this.log.error("Protocol client listener crashed", error)
    })
  }

  private async handleTransportMessage(message: ServerProtocolMessage) {
    switch (message.body.oneofKind) {
      case "connectionOpen":
        await this.connectionOpen()
        this.log.info("Protocol client: Connection established")
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
        this.log.trace("Received ack", message.body.ack.msgId)
        await this.events.send({ type: "ack", msgId: message.body.ack.msgId })
        break

      case "message":
        this.log.trace("Received server message", message.body.message)
        if (message.body.message.payload.oneofKind === "update") {
          await this.events.send({ type: "updates", updates: message.body.message.payload.update })
        } else {
          this.log.trace("Protocol client: Unhandled message type")
        }
        break

      case "pong":
        this.log.trace("Received pong", message.body.pong.nonce)
        this.pingPong.pong(message.body.pong.nonce)
        break

      case "connectionError":
        this.log.error("Protocol client: connection error")
        this.handleClientFailure()
        break

      default:
        this.log.trace("Protocol client: Unhandled message type", message.body)
        break
    }
  }

  private async sendConnectionInit() {
    this.log.trace("sending connection init")

    const connectionInit = this.getConnectionInit()
    if (!connectionInit) {
      this.log.error("No token available for connection init")
      throw new ProtocolClientError("not-authorized")
    }

    const message = this.wrapMessage({
      oneofKind: "connectionInit",
      connectionInit,
    })

    await this.transport.send(message)
    this.log.trace("connection init sent successfully")
  }

  private async authenticate() {
    try {
      await this.sendConnectionInit()
      this.log.trace("Sent authentication message")
      this.startAuthenticationTimeout()
    } catch (error) {
      this.log.error("Failed to authenticate, attempting restart", error)
      this.handleClientFailure()
    }
  }

  private async connectionOpen() {
    this.state = "open"
    await this.events.send({ type: "open" })
    this.stopAuthenticationTimeout()
    if (this.reconnectionTimer) {
      clearTimeout(this.reconnectionTimer)
      this.reconnectionTimer = null
    }
    this.connectionAttemptNo = 0
    this.pingPong.start()
  }

  private async connecting() {
    this.state = "connecting"
    await this.events.send({ type: "connecting" })
    this.stopAuthenticationTimeout()
    this.pingPong.stop()
    this.cancelAllRpcContinuations(new ProtocolClientError("not-connected"))
  }

  private async reset() {
    this.seq = 0
    this.lastTimestamp = 0
    this.sequence = 0
    this.connectionAttemptNo = 0
    this.stopAuthenticationTimeout()
    if (this.reconnectionTimer) {
      clearTimeout(this.reconnectionTimer)
      this.reconnectionTimer = null
    }
    this.pingPong.stop()
    this.cancelAllRpcContinuations(new ProtocolClientError("stopped"))
  }

  private startAuthenticationTimeout() {
    this.stopAuthenticationTimeout()
    this.authenticationTimeout = setTimeout(() => {
      if (this.state === "connecting") {
        this.log.error("Authentication timeout. Reconnecting")
        void this.reconnect({ skipDelay: true })
      }
    }, 10_000)
  }

  private stopAuthenticationTimeout() {
    if (!this.authenticationTimeout) return
    clearTimeout(this.authenticationTimeout)
    this.authenticationTimeout = null
  }

  private handleClientFailure() {
    this.log.debug("Client failure. Reconnecting")
    this.connectionAttemptNo = (this.connectionAttemptNo + 1) >>> 0
    this.stopAuthenticationTimeout()

    if (this.reconnectionTimer) {
      clearTimeout(this.reconnectionTimer)
    }

    this.reconnectionTimer = setTimeout(() => {
      if (this.state === "open") return
      void this.reconnect({ skipDelay: true })
    }, this.getReconnectionDelay() * 1000)
  }

  private getReconnectionDelay() {
    const attemptNo = this.connectionAttemptNo

    if (attemptNo >= 8) {
      return 8.0 + Math.random() * 5.0
    }

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
    const timestamp = this.currentTimestamp()
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
    const continuation = this.getAndRemoveRpcContinuation(msgId)
    continuation?.resolve(rpcResult)
  }

  private completeRpcError(msgId: bigint, rpcError: RpcError) {
    const error = new ProtocolClientError("rpc-error", {
      code: rpcError.code,
      message: rpcError.message,
    })
    const continuation = this.getAndRemoveRpcContinuation(msgId)
    continuation?.reject(error)
  }

  private failRpcContinuation(msgId: bigint, error: Error) {
    const continuation = this.getAndRemoveRpcContinuation(msgId)
    continuation?.reject(error)
  }

  private getAndRemoveRpcContinuation(msgId: bigint) {
    const continuation = this.rpcContinuations.get(msgId)
    if (!continuation) return null
    if (continuation.timeout) {
      clearTimeout(continuation.timeout)
    }
    this.rpcContinuations.delete(msgId)
    return continuation
  }

  private cancelAllRpcContinuations(error: Error) {
    for (const continuation of this.rpcContinuations.values()) {
      continuation.reject(error)
      if (continuation.timeout) {
        clearTimeout(continuation.timeout)
      }
    }
    this.rpcContinuations.clear()
  }
}

class ProtocolClientError extends Error {
  constructor(
    code: "not-authorized" | "not-connected" | "rpc-error" | "stopped" | "timeout",
    details?: { code?: number; message?: string },
  ) {
    super(details?.message ?? code)
    this.name = `ProtocolClientError:${code}`
  }
}
