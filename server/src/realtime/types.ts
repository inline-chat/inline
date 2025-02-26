import type { RpcResult, ServerProtocolMessage } from "@in/protocol/core"
import type { ServerWebSocket } from "bun"
import type { ElysiaWS } from "elysia/ws"

export type Ws = ElysiaWS<ServerWebSocket<any>>

export type RootContext = {
  ws: Ws
  connectionId: string
}

export type HandlerContext = {
  userId: number
  sessionId: number
  connectionId: string
  sendRaw: (message: ServerProtocolMessage) => void
  sendRpcReply: (result: RpcResult["result"]) => void
}
