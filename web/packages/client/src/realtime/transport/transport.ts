import type { ClientMessage } from "@inline-chat/protocol/core"
import type { AsyncChannel } from "../../utils/async-channel"
import type { TransportEvent } from "../types"

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
  events: AsyncChannel<TransportEvent>
  start: () => Promise<void>
  stop: () => Promise<void>
  send: (message: ClientMessage) => Promise<void>
  stopConnection: () => Promise<void>
  reconnect: (options?: { skipDelay?: boolean }) => Promise<void>
}
