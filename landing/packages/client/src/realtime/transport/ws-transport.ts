import { ClientMessage, ServerProtocolMessage } from "@inline-chat/protocol/core"
import { Log, type LogLevel } from "@inline/log"
import { AsyncChannel } from "../../utils/async-channel"
import { TransportError, type Transport } from "./transport"
import type { TransportEvent } from "../types"

const CONNECTION_TIMEOUT_MS = 10_000
const WATCHDOG_INTERVAL_MS = 10_000
const STUCK_CONNECTING_MS = 60_000

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
  private connectionAttemptNo = 0
  private connectingStartTime: number | null = null

  private socket: WebSocket | null = null
  private reconnectionTimer: ReturnType<typeof setTimeout> | null = null
  private connectionTimeoutTimer: ReturnType<typeof setTimeout> | null = null
  private watchdogTimer: ReturnType<typeof setInterval> | null = null

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
    this.startWatchdog()
    await this.openConnection()
  }

  async stop() {
    if (this.state === "idle") return
    this.stopWatchdog()
    await this.setIdle()
    await this.stopConnection()
  }

  async send(message: ClientMessage) {
    if (this.state !== "connected" || !this.socket || this.socket.readyState !== WebSocket.OPEN) {
      throw TransportError.notConnected()
    }

    this.log.trace("sending message", message)
    const payload = ClientMessage.toBinary(message)
    this.socket.send(payload)
  }

  async stopConnection() {
    this.log.trace("stopping connection")
    this.cleanUpPreviousConnection()
  }

  async reconnect(options?: { skipDelay?: boolean }) {
    const skipDelay = options?.skipDelay ?? false

    await this.setConnecting()
    await this.stopConnection()

    this.connectionAttemptNo = (this.connectionAttemptNo + 1) >>> 0

    if (this.reconnectionTimer) {
      clearTimeout(this.reconnectionTimer)
      this.reconnectionTimer = null
    }

    const delay = this.getReconnectionDelay()
    this.log.trace(`Reconnection attempt #${this.connectionAttemptNo} with ${delay}s delay`)

    this.reconnectionTimer = setTimeout(() => {
      this.reconnectionTimer = null

      if (this.state === "idle" || this.state === "connected") {
        this.log.debug("Not reconnecting because state is idle or connected")
        return
      }

      void this.openConnection()
    }, skipDelay ? 0 : delay * 1000)
  }

  private cleanUpPreviousConnection() {
    if (this.reconnectionTimer) {
      clearTimeout(this.reconnectionTimer)
      this.reconnectionTimer = null
    }

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

  private getReconnectionDelay(): number {
    const attemptNo = this.connectionAttemptNo

    if (attemptNo >= 8) {
      return 7.0 + Math.random() * 4.0
    }

    return Math.min(8.0, 0.2 + Math.pow(attemptNo, 1.5) * 0.4)
  }

  private startWatchdog() {
    this.stopWatchdog()
    this.watchdogTimer = setInterval(() => {
      if (this.state !== "connecting") return
      const hasNoActiveTasks = this.reconnectionTimer === null && this.connectionTimeoutTimer === null
      const hasBeenConnectingTooLong =
        this.connectingStartTime !== null && Date.now() - this.connectingStartTime > STUCK_CONNECTING_MS

      if (hasNoActiveTasks || hasBeenConnectingTooLong) {
        this.log.debug("Watchdog: detected stuck connection, triggering recovery")
        void this.handleError(new Error("Watchdog detected stuck connection"))
      }
    }, WATCHDOG_INTERVAL_MS)
  }

  private stopWatchdog() {
    if (!this.watchdogTimer) return
    clearInterval(this.watchdogTimer)
    this.watchdogTimer = null
  }

  private startConnectionTimeout(socket: WebSocket) {
    const currentAttemptNo = this.connectionAttemptNo
    this.connectionTimeoutTimer = setTimeout(() => {
      if (this.connectionAttemptNo !== currentAttemptNo) return
      if (this.state !== "connecting") return
      if (this.socket !== socket) return

      this.log.debug("Connection attempt timed out after 10 seconds")
      socket.close(1006, "Connection timeout")
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

    await this.setConnecting()
    await this.reconnect()
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

    this.connectionAttemptNo = 0
    this.stopConnectionTimeout()
    await this.setConnected()
  }

  private async setConnected() {
    if (this.state === "connected") return
    this.state = "connected"
    this.connectingStartTime = null
    this.log.trace("Transport connected")
    this.stopWatchdog()
    await this.events.send({ type: "connected" })
  }

  private async setConnecting() {
    if (this.state === "connecting") return
    this.state = "connecting"
    this.connectingStartTime = Date.now()
    this.startWatchdog()
    await this.events.send({ type: "connecting" })
  }

  private async setIdle() {
    if (this.state === "idle") return
    this.state = "idle"
    this.connectingStartTime = null
    this.log.trace("Transport stopping")
    await this.events.send({ type: "stopping" })
  }
}
