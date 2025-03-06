import { Method, type ConnectionInit, type ConnectionOpen, type RpcCall, type RpcResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { getUserIdFromToken } from "@in/server/controllers/plugins"
import { connectionManager } from "@in/server/ws/connections"
import { getMe } from "@in/server/realtime/handlers/getMe"
import { Log } from "@in/server/utils/log"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { deleteMessage } from "@in/server/realtime/handlers/messages.deleteMessage"
import { sendMessage } from "@in/server/realtime/handlers/messages.sendMessage"
import { getChatHistory } from "@in/server/realtime/handlers/messages.getChatHistory"

export const handleRpcCall = async (call: RpcCall, handlerContext: HandlerContext): Promise<RpcResult["result"]> => {
  // user still unauthenticated here.
  Log.shared.debug("rpc call", call.method)

  switch (call.method) {
    case Method.GET_ME: {
      if (call.input.oneofKind !== "getMe") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await getMe(call.input, handlerContext)
      return { oneofKind: "getMe", getMe: result }
    }

    case Method.DELETE_MESSAGES: {
      if (call.input.oneofKind !== "deleteMessages") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await deleteMessage(call.input.deleteMessages, handlerContext)
      return { oneofKind: "deleteMessages", deleteMessages: result }
    }

    case Method.SEND_MESSAGE: {
      if (call.input.oneofKind !== "sendMessage") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await sendMessage(call.input.sendMessage, handlerContext)
      return { oneofKind: "sendMessage", sendMessage: result }
    }

    case Method.GET_CHAT_HISTORY: {
      if (call.input.oneofKind !== "getChatHistory") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await getChatHistory(call.input.getChatHistory, handlerContext)
      return { oneofKind: "getChatHistory", getChatHistory: result }
    }

    default:
      Log.shared.error(`Unknown method: ${call.method}`)
      throw RealtimeRpcError.BadRequest
  }
}
