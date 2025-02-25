import { connectionManager } from "@in/server/ws/connections"
import {
  ClientMessage,
  ConnectionInit,
  RpcError,
  RpcError_Code,
  RpcResult,
  ServerMessage,
  ServerProtocolMessage,
  UpdatesPayload,
} from "../protocol/core"
import type { HandlerContext, RootContext, Ws } from "./types"
import { handleConnectionInit } from "@in/server/realtime/handlers/_connectionInit"
import { Log, LogLevel } from "@in/server/utils/log"
import { handleRpcCall } from "@in/server/realtime/handlers/_rpc"

const log = new Log("realtime", LogLevel.DEBUG)

export const handleMessage = async (message: ClientMessage, rootContext: RootContext) => {
  const { ws, connectionId } = rootContext

  const conn = connectionManager.getConnection(connectionId)

  const sendRaw = (message: ServerProtocolMessage) => {
    ws.raw.sendBinary(ServerProtocolMessage.toBinary(message), true)
  }

  const sendConnectionOpen = () => {
    sendRaw({
      id: genId(),
      body: {
        oneofKind: "connectionOpen",
        connectionOpen: {},
      },
    })
  }

  const sendRpcReply = (result: RpcResult["result"]) => {
    handlerContext.sendRaw({
      id: genId(),
      body: {
        oneofKind: "rpcResult",
        rpcResult: {
          reqMsgId: message.id,
          result: result,
        },
      },
    })
  }

  const handlerContext: HandlerContext = {
    userId: conn?.userId ?? 0,
    sessionId: conn?.sessionId ?? 0,
    connectionId,
    sendRaw,
    sendRpcReply,
  }

  try {
    switch (message.body.oneofKind) {
      case "connectionInit":
        let _ = await handleConnectionInit(message.body.connectionInit, handlerContext)
        sendConnectionOpen()
        break

      case "rpcCall":
        let result = await handleRpcCall(message.body.rpcCall, handlerContext)
        sendRpcReply(result)
        break

      default:
        log.error("unhandled message")
        break
    }
  } catch (e) {
    log.error("error handling message", e)
    if (message.body.oneofKind === "connectionInit") {
      ws.close()
    } else {
      sendRaw({
        id: message.id,
        body: {
          oneofKind: "rpcError",
          rpcError: {
            reqMsgId: message.id,
            errorCode: RpcError_Code.UNKNOWN,
            message: "Internal server error",
          },
        },
      })
    }
  }
}

// ID generator with 2025 epoch
const EPOCH = 1735689600000n // 2025-01-01T00:00:00.000Z
let lastTimestamp = 0n
let sequence = 0n

const genId = (): bigint => {
  const timestamp = BigInt(Date.now()) - EPOCH

  if (timestamp === lastTimestamp) {
    sequence = (sequence + 1n) & 4095n // Keep sequence within 12 bits
  } else {
    sequence = 0n
    lastTimestamp = timestamp
  }

  // Shift timestamp left by 22 bits (12 for sequence, 10 for machine/process id if needed)
  // Currently using only timestamp (42 bits) and sequence (12 bits)
  return (timestamp << 22n) | sequence
}

const sendRaw = (ws: Ws, message: ServerProtocolMessage) => {
  ws.raw.sendBinary(ServerProtocolMessage.toBinary(message), true)
}

export const sendMessageToRealtimeUser = async (userId: number, payload: ServerMessage["payload"]) => {
  const connections = connectionManager.getUserConnections(userId)

  for (let conn of connections) {
    // re-using id in different sockets should be fine, even beneficial as it avoid duplicate ones
    let id = genId()
    sendRaw(conn.ws, {
      id: id,
      body: {
        oneofKind: "message",
        message: {
          payload,
        },
      },
    })
  }
}

export class RealtimeUpdates {
  static pushToUser(userId: number, updates: UpdatesPayload["updates"]) {
    sendMessageToRealtimeUser(userId, {
      oneofKind: "update",
      update: {
        updates: updates,
      },
    })
  }
}
