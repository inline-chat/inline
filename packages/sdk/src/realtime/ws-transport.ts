import { WebSocket } from "ws"
import { ClientMessage, ServerProtocolMessage } from "@inline-chat/protocol/core"
import { AsyncChannel } from "../utils/async-channel.js"
import { TransportError, type Transport, type TransportReconnectOptions } from "./transport.js"
import type { TransportEvent } from "./types.js"
import type { InlineSdkLogger } from "../sdk/logger.js"

type ConnectionState = "idle" | "connecting" | "connected"

export type WebSocketTransportOptions = {
  url: string
  logger?: InlineSdkLogger
}

export class WebSocketTransport implements Transport {
  readonly events = new AsyncChannel<TransportEvent>()

  private readonly url: string
  private readonly log: InlineSdkLogger

  private state: ConnectionState = "idle"
  private connectionAttemptNo = 0

  private socket: WebSocket | null = null
  private reconnectionTimer: ReturnType<typeof setTimeout> | null = null
  private lastConnectStartedAt: number | null = null
  private lastConnectedAt: number | null = null
  private lastDisconnectedAt: number | null = null
  private lastMessageAt: number | null = null
  private lastCloseCode: number | null = null
  private lastCloseReason: string | null = null
  private lastErrorAt: number | null = null
  private lastErrorMessage: string | null = null
  private lastReconnectScheduledAt: number | null = null
  private lastReconnectDelayMs: number | null = null
  private lastReconnectCause: string | null = null
  private reconnectCount = 0

  constructor(options: WebSocketTransportOptions) {
    this.url = options.url
    this.log = options.logger ?? {}
  }

  async start() {
    if (this.state !== "idle") return
    await this.setConnecting()
    await this.openConnection()
  }

  async stop() {
    if (this.state === "idle") return
    await this.setIdle()
    this.cleanUpPreviousConnection()
  }

  async send(message: ClientMessage) {
    if (this.state !== "connected" || !this.socket || this.socket.readyState !== WebSocket.OPEN) {
      throw TransportError.notConnected()
    }
    this.socket.send(ClientMessage.toBinary(message))
  }

  async stopConnection() {
    this.cleanUpPreviousConnection()
  }

  async reconnect(options?: TransportReconnectOptions) {
    const skipDelay = options?.skipDelay ?? false

    await this.setConnecting()
    this.cleanUpPreviousConnection()

    this.connectionAttemptNo = (this.connectionAttemptNo + 1) >>> 0
    const delaySeconds = this.getReconnectionDelaySeconds(this.connectionAttemptNo)
    const delayMs = Math.round(delaySeconds * 1000)
    const cause = options?.cause?.trim() || "unspecified"
    this.lastReconnectScheduledAt = Date.now()
    this.lastReconnectDelayMs = delayMs
    this.lastReconnectCause = cause
    this.reconnectCount += 1
    this.log.warn?.(
      `WebSocket reconnect scheduled (attempt=${this.connectionAttemptNo}, delayMs=${delayMs}, cause=${cause})`,
    )

    this.reconnectionTimer = setTimeout(() => {
      this.reconnectionTimer = null
      if (this.state === "idle" || this.state === "connected") return
      void this.openConnection()
    }, skipDelay ? 0 : delaySeconds * 1000)
  }

  private cleanUpPreviousConnection() {
    if (this.reconnectionTimer) {
      clearTimeout(this.reconnectionTimer)
      this.reconnectionTimer = null
    }

    if (this.socket) {
      const socket = this.socket
      this.socket = null
      socket.removeAllListeners()
      this.closeSocketSafely(socket)
    }
  }

  private closeSocketSafely(socket: WebSocket) {
    try {
      if (socket.readyState === WebSocket.CONNECTING) {
        socket.terminate()
        return
      }
      if (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CLOSING) {
        socket.close()
      }
    } catch (error) {
      this.log.warn?.("WebSocket cleanup close failed", error)
      try {
        socket.terminate()
      } catch {
        // no-op
      }
    }
  }

  private getReconnectionDelaySeconds(attemptNo: number): number {
    // Exponential-ish backoff with jitter.
    // Cap quickly so callers don't stall for too long.
    const base = Math.min(8.0, 0.2 + Math.pow(attemptNo, 1.5) * 0.4)
    const jitter = attemptNo >= 8 ? Math.random() * 4.0 : 0
    return base + jitter
  }

  private async openConnection() {
    if (this.state === "idle") return

    this.lastConnectStartedAt = Date.now()
    const socket = new WebSocket(this.url)
    this.socket = socket

    socket.on("open", () => {
      void this.connectionDidOpen(socket)
    })

    socket.on("message", (data) => {
      void this.handleMessage(socket, data)
    })

    socket.on("close", (code, reason) => {
      void this.handleClose(socket, code, reason)
    })

    socket.on("error", (error) => {
      void this.handleError(socket, error)
    })
  }

  private async connectionDidOpen(socket: WebSocket) {
    if (this.socket !== socket) return
    if (this.state !== "connecting") return

    this.connectionAttemptNo = 0
    this.state = "connected"
    this.lastConnectedAt = Date.now()
    this.lastDisconnectedAt = null
    await this.events.send({ type: "connected" })
  }

  private async handleMessage(socket: WebSocket, data: WebSocket.RawData) {
    if (this.socket !== socket) return
    try {
      const payload = this.coerceBinary(data)
      const message = ServerProtocolMessage.fromBinary(payload)
      this.lastMessageAt = Date.now()
      await this.events.send({ type: "message", message })
    } catch (error) {
      this.log.error?.("Failed to decode message", error)
    }
  }

  private coerceBinary(data: WebSocket.RawData): Uint8Array {
    if (data instanceof ArrayBuffer) return new Uint8Array(data)
    // Covers Buffer and other typed-array views.
    if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
    if (Array.isArray(data)) return new Uint8Array(Buffer.concat(data))
    throw new Error("Unsupported WebSocket message payload")
  }

  private async handleClose(socket: WebSocket, code: number, reason: Buffer) {
    if (this.socket !== socket) return
    if (this.state === "idle") return
    const reasonText = stringifyCloseReason(reason)
    this.lastDisconnectedAt = Date.now()
    this.lastCloseCode = code
    this.lastCloseReason = reasonText
    const connectedForMs =
      this.lastConnectedAt != null ? Math.max(0, this.lastDisconnectedAt - this.lastConnectedAt) : null
    this.log.warn?.(
      `WebSocket closed (code=${code}, reason=${reasonText || "none"}${connectedForMs != null ? `, connectedForMs=${connectedForMs}` : ""})`,
    )
    await this.reconnect({ cause: `socket-close:${code}${reasonText ? `:${reasonText}` : ""}` })
  }

  private async handleError(socket: WebSocket, error: unknown) {
    if (this.socket !== socket) return
    if (this.state === "idle") return
    const summary = summarizeError(error)
    this.lastErrorAt = Date.now()
    this.lastErrorMessage = summary
    this.log.error?.(`WebSocket error: ${summary}`)
    await this.reconnect({ cause: `socket-error:${summary}` })
  }

  private async setIdle() {
    if (this.state === "idle") return
    this.state = "idle"
    await this.events.send({ type: "stopping" })
  }

  private async setConnecting() {
    if (this.state === "connecting") return
    this.state = "connecting"
    await this.events.send({ type: "connecting" })
  }

  getDiagnostics() {
    return {
      kind: "websocket",
      url: redactUrlForDiagnostics(this.url),
      state: this.state,
      connectionAttemptNo: this.connectionAttemptNo,
      reconnectCount: this.reconnectCount,
      lastConnectStartedAt: this.lastConnectStartedAt,
      lastConnectedAt: this.lastConnectedAt,
      lastDisconnectedAt: this.lastDisconnectedAt,
      lastMessageAt: this.lastMessageAt,
      lastCloseCode: this.lastCloseCode,
      lastCloseReason: this.lastCloseReason,
      lastErrorAt: this.lastErrorAt,
      lastErrorMessage: this.lastErrorMessage,
      lastReconnectScheduledAt: this.lastReconnectScheduledAt,
      lastReconnectDelayMs: this.lastReconnectDelayMs,
      lastReconnectCause: this.lastReconnectCause,
      socketReadyState: this.socket?.readyState ?? null,
    }
  }
}

function stringifyCloseReason(reason: Buffer): string {
  const text = reason.toString("utf8").trim()
  return text
}

function summarizeError(error: unknown): string {
  if (error instanceof Error) {
    const code = typeof (error as Error & { code?: unknown }).code === "string" ? (error as Error & { code: string }).code : null
    return code ? `${error.name}: ${error.message} (code=${code})` : `${error.name}: ${error.message}`
  }
  return String(error)
}

function redactUrlForDiagnostics(raw: string): string {
  try {
    const url = new URL(raw)
    return `${url.protocol}//${url.host}${url.pathname}`
  } catch {
    return raw
  }
}
