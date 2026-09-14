import type { ClientMessage } from "@inline-chat/protocol/core"
import type { AsyncChannel } from "../../utils/async-channel"
import type { TransportEvent } from "../types"

export type TransportErrorCode = "not-connected" | "send-failed"

export class TransportError extends Error {
  readonly code: TransportErrorCode
  override readonly cause?: unknown

  constructor(code: TransportErrorCode, message: string, cause?: unknown) {
    super(message)
    this.name = "TransportError"
    this.code = code
    this.cause = cause
  }

  static notConnected() {
    return new TransportError("not-connected", "Transport is not connected")
  }

  static sendFailed(cause: unknown) {
    return new TransportError("send-failed", "Transport failed to send", cause)
  }
}

export type Transport = {
  events: AsyncChannel<TransportEvent>
  start: () => Promise<void>
  stop: () => Promise<void>
  send: (message: ClientMessage) => Promise<void>
}
