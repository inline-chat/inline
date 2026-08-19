import type { ClientMessage } from "@inline-chat/protocol/core"
import type { TransportEvent } from "./types.js"

export class TransportError extends Error {
  constructor(
    message: string,
    readonly code:
      | "capacity-exceeded"
      | "generic"
      | "commit-outcome-unknown"
      | "rejected-before-execution" = "generic",
  ) {
    super(message)
    this.name = "TransportError"
  }

  static notConnected() {
    return new TransportError("Transport is not connected")
  }

  static commitOutcomeUnknown(message: string) {
    return new TransportError(message, "commit-outcome-unknown")
  }

  static capacityExceeded(message: string) {
    return new TransportError(message, "capacity-exceeded")
  }

  static rejectedBeforeExecution(message: string) {
    return new TransportError(message, "rejected-before-execution")
  }
}

export type TransportReconnectOptions = {
  skipDelay?: boolean
  cause?: string
}

export type Transport = {
  // Async event stream of transport lifecycle + received messages.
  events: AsyncIterable<TransportEvent>
  start: () => Promise<void>
  stop: () => Promise<void>
  send: (message: ClientMessage) => Promise<void>
  stopConnection: () => Promise<void>
  reconnect: (options?: TransportReconnectOptions) => Promise<void>
  getDiagnostics?: () => unknown
}
