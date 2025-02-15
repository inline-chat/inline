import type { RpcResult, ServerProtocolMessage } from "@in/server/protocol/core"
import type { ServerWebSocket } from "bun"
import type { ElysiaWS } from "elysia/ws"

export type RootContext = {
  ws: ElysiaWS<ServerWebSocket<any>>
  connectionId: string
}

export type HandlerContext = {
  userId: number
  sessionId: number
  connectionId: string
  sendRaw: (message: ServerProtocolMessage) => void
  sendRpcReply: (result: RpcResult["result"]) => void
}
