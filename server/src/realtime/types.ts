import type { RpcResult, ServerProtocolMessage } from "@inline-chat/protocol/core"
import type { ServerWebSocket } from "bun"
import type { ElysiaWS } from "elysia/ws"

export type Ws = ElysiaWS<ServerWebSocket<any>>

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
