import { ClientMessage, ServerProtocolMessage } from "@inline-chat/protocol/core"
import { Log, type LogLevel } from "@inline/log"
import { AsyncChannel } from "../../utils/async-channel"
import { TransportError, type Transport } from "./transport"
import type { TransportEvent } from "../types"

const CONNECTION_TIMEOUT_MS = 10_000

type ConnectionState = "idle" | "connecting" | "connected"

export type WebSocketTransportOptions = {
  url: string
  logLevel?: LogLevel
  logger?: Log
}

export class WebSocketTransport implements Transport {
  readonly events = new AsyncChannel<TransportEvent>()

  private readonly log: Log
  private readonly url: string

  private state: ConnectionState = "idle"

  private socket: WebSocket | null = null
  private connectionTimeoutTimer: ReturnType<typeof setTimeout> | null = null

  constructor(options: WebSocketTransportOptions) {
    const baseLogger = options.logger ?? new Log("RealtimeV2.WebSocketTransport", options.logLevel)
    this.log = baseLogger
    this.url = options.url
  }

  async start() {
    if (this.state !== "idle") {
      this.log.error("Not starting transport because state is not idle", this.state)
      return
    }

    await this.setConnecting()
    await this.openConnection()
  }

  async stop() {
    if (this.state === "idle") return
    this.cleanUpPreviousConnection()
    await this.setIdle()
  }

  async send(message: ClientMessage) {
    if (this.state !== "connected" || !this.socket || this.socket.readyState !== WebSocket.OPEN) {
      throw TransportError.notConnected()
    }

    this.log.trace("sending message", message)
    const payload = ClientMessage.toBinary(message)
    try {
      if (payload.buffer instanceof ArrayBuffer) {
        this.socket.send(new Uint8Array(payload.buffer, payload.byteOffset, payload.byteLength))
      } else {
        this.socket.send(Uint8Array.from(payload))
      }
    } catch (error) {
      throw TransportError.sendFailed(error)
    }
  }

  private cleanUpPreviousConnection() {
    this.stopConnectionTimeout()

    if (this.socket) {
      this.socket.onopen = null
      this.socket.onclose = null
      this.socket.onerror = null
      this.socket.onmessage = null
      this.socket.close()
      this.socket = null
    }
  }

  private startConnectionTimeout(socket: WebSocket) {
    this.connectionTimeoutTimer = setTimeout(() => {
      if (this.state !== "connecting") return
      if (this.socket !== socket) return

      this.log.debug("Connection attempt timed out after 10 seconds")
      socket.close()
      void this.handleError(new Error("Connection attempt timed out"))
    }, CONNECTION_TIMEOUT_MS)
  }

  private stopConnectionTimeout() {
    if (!this.connectionTimeoutTimer) return
    clearTimeout(this.connectionTimeoutTimer)
    this.connectionTimeoutTimer = null
  }

  private async openConnection() {
    this.log.trace("Opening connection")

    if (this.state === "idle") {
      this.log.debug("Not opening connection because state is idle")
      return
    }

    if (typeof WebSocket === "undefined") {
      this.log.error("WebSocket is not available in this environment")
      await this.setDisconnected("websocket-unavailable")
      return
    }

    this.cleanUpPreviousConnection()
    await this.setConnecting()

    const socket = new WebSocket(this.url)
    socket.binaryType = "arraybuffer"
    this.socket = socket

    this.startConnectionTimeout(socket)

    socket.onopen = () => {
      void this.connectionDidOpen(socket)
    }

    socket.onmessage = (event) => {
      void this.handleMessage(socket, event)
    }

    socket.onclose = (event) => {
      void this.handleClose(socket, event)
    }

    socket.onerror = () => {
      void this.handleError(new Error("WebSocket connection error"), socket)
    }
  }

  private async handleMessage(socket: WebSocket, event: MessageEvent) {
    if (this.socket !== socket) {
      this.log.trace("Ignoring message for stale WebSocket")
      return
    }

    const { data } = event
    if (typeof data === "string") {
      this.log.warn("Received string frame, expected binary data")
      return
    }

    try {
      const payload = await this.coerceBinary(data)
      const message = ServerProtocolMessage.fromBinary(payload)
      await this.events.send({ type: "message", message })
    } catch (error) {
      this.log.error("Failed to decode message", error)
    }
  }

  private async coerceBinary(data: Blob | ArrayBuffer): Promise<Uint8Array> {
    if (data instanceof ArrayBuffer) {
      return new Uint8Array(data)
    }

    const buffer = await data.arrayBuffer()
    return new Uint8Array(buffer)
  }

  private async handleError(error: unknown, socket?: WebSocket) {
    if (socket && this.socket !== socket) {
      this.log.trace("Ignoring error for stale WebSocket", error)
      return
    }

    this.log.error("WebSocket connection error", error)

    if (this.state === "idle") {
      this.log.trace("Ignoring error because state is idle")
      return
    }

    this.cleanUpPreviousConnection()
    await this.setDisconnected(
      error instanceof Error ? error.message : String(error),
    )
  }

  private async handleClose(socket: WebSocket, event: CloseEvent) {
    if (this.socket !== socket) {
      this.log.trace("Ignoring close for stale WebSocket")
      return
    }

    this.log.trace("WebSocket closed", event.code, event.reason)
    await this.handleError(new Error(`WebSocket closed ${event.code} ${event.reason}`), socket)
  }

  private async connectionDidOpen(socket: WebSocket) {
    if (this.socket !== socket) {
      this.log.trace("Ignoring didOpen for stale WebSocket")
      return
    }

    this.stopConnectionTimeout()
    await this.setConnected()
  }

  private async setConnected() {
    if (this.state === "connected") return
    this.state = "connected"
    this.log.trace("Transport connected")
    await this.events.send({ type: "connected" })
  }

  private async setConnecting() {
    if (this.state === "connecting") return
    this.state = "connecting"
    await this.events.send({ type: "connecting" })
  }

  private async setIdle() {
    if (this.state === "idle") return
    this.state = "idle"
    this.log.trace("Transport stopping")
    await this.events.send({ type: "stopping" })
  }

  private async setDisconnected(reason?: string) {
    if (this.state === "idle") return
    this.state = "idle"
    await this.events.send({ type: "disconnected", reason })
  }
}
