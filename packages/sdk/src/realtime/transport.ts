import type { ClientMessage } from "@inline-chat/protocol/core"
import type { TransportEvent } from "./types.js"

export class TransportError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "TransportError"
  }

  static notConnected() {
    return new TransportError("Transport is not connected")
  }
}

export type Transport = {
  // Async event stream of transport lifecycle + received messages.
  events: AsyncIterable<TransportEvent>
  start: () => Promise<void>
  stop: () => Promise<void>
  send: (message: ClientMessage) => Promise<void>
  stopConnection: () => Promise<void>
  reconnect: (options?: { skipDelay?: boolean }) => Promise<void>
}
