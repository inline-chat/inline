import type { RpcResult, ServerProtocolMessage } from "@inline-chat/protocol/core"

/**
 * The socket surface the v2 protocol handlers and the connection registry use.
 * `legacyHostAdapter.effect.ts` adapts the production transport peer to it.
 */
export interface Ws {
  readonly id: string
  readonly close: (code?: number, reason?: string) => void
  readonly raw: {
    readonly sendBinary: (bytes: Uint8Array, compress?: boolean) => number
  }
}

export type RealtimeRequestMetadata = {
  ip?: string
  userAgent?: string
  origin?: string
  host?: string
}

export type RootContext = {
  ws: Ws
  connectionId: string
  requestMetadata?: RealtimeRequestMetadata
}

export type HandlerContext = {
  userId: number
  sessionId: number
  isBot?: boolean
  connectionId: string
  /** V3 application deadline. Handlers should forward this to cancellable downstream work. */
  signal?: AbortSignal
  sendRaw: (message: ServerProtocolMessage) => void
  sendRpcReply: (result: RpcResult["result"]) => void
  inlineProtocol?: {
    permanentAuthKeyId: Uint8Array
  }
}
