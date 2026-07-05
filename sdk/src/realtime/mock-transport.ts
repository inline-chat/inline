import type { ClientMessage, ServerProtocolMessage } from "@inline-chat/protocol/core"
import { AsyncChannel } from "../utils/async-channel.js"
import type { TransportEvent } from "./types.js"
import { TransportError, type Transport } from "./transport.js"

export type MockTransportState = "idle" | "connecting" | "connected"

export class MockTransport implements Transport {
  readonly events = new AsyncChannel<TransportEvent>()
  readonly sent: ClientMessage[] = []

  state: MockTransportState = "idle"

  async start() {
    if (this.state !== "idle") return
    this.state = "connecting"
    await this.events.send({ type: "connecting" })
  }

  async stop() {
    if (this.state === "idle") return
    this.state = "idle"
    await this.events.send({ type: "stopping" })
  }

  async send(message: ClientMessage) {
    if (this.state !== "connected") {
      throw TransportError.notConnected()
    }
    this.sent.push(message)
  }

  async stopConnection() {
    if (this.state === "idle") return
    this.state = "connecting"
  }

  async reconnect() {
    this.state = "connecting"
    await this.events.send({ type: "connecting" })
  }

  async connect() {
    this.state = "connected"
    await this.events.send({ type: "connected" })
  }

  async emitMessage(message: ServerProtocolMessage) {
    await this.events.send({ type: "message", message })
  }
}
