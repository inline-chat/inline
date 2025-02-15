import {
  Method,
  type ConnectionInit,
  type ConnectionOpen,
  type RpcCall,
  type RpcResult,
} from "@in/server/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { getUserIdFromToken } from "@in/server/controllers/plugins"
import { connectionManager } from "@in/server/ws/connections"
import { getMe } from "@in/server/realtime/handlers/getMe"

export const handleRpcCall = async (call: RpcCall, handlerContext: HandlerContext): Promise<RpcResult["result"]> => {
  // user still unauthenticated here.
  console.log("rpc call", call.method)

  switch (call.method) {
    case Method.GET_ME: {
      let result = await getMe(call.params, handlerContext)
      return { oneofKind: "getMe", getMe: result }
    }

    default:
      throw new Error(`Unknown method: ${call.method}`) // todo: make rpc error
  }
}
