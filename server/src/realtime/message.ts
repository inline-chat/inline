import { connectionManager } from "@in/server/ws/connections"
import {
  ClientMessage,
  ConnectionInit,
  Method,
  RpcError,
  RpcError_Code,
  RpcResult,
  ServerMessage,
  ServerProtocolMessage,
  UpdatesPayload,
} from "@in/protocol/core"
import type { HandlerContext, RootContext, Ws } from "./types"
import { handleConnectionInit } from "@in/server/realtime/handlers/_connectionInit"
import { Log, LogLevel } from "@in/server/utils/log"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { InlineError } from "@in/server/types/errors"

const log = new Log("realtime")

const pickIdFields = (value: unknown): Record<string, unknown> | undefined => {
  if (!value || typeof value !== "object") return undefined
  const obj = value as Record<string, unknown>
  const keys = ["userId", "peerId", "chatId", "spaceId", "messageId", "sessionId", "botId", "memberId", "inviteeId"]
  const ids: Record<string, unknown> = {}

  for (const key of keys) {
    const entry = obj[key]
    if (entry !== undefined && entry !== null) {
      ids[key] = entry
    }
  }

  return Object.keys(ids).length > 0 ? ids : undefined
}

const getMethodName = (method: number): string => {
  return Method[method] ?? `UNKNOWN_METHOD_${method}`
}

// Cache for lazily-loaded RPC handler to avoid circular import and per-call dynamic import cost
let rpcHandlerModulePromise: Promise<typeof import("@in/server/realtime/handlers/_rpc")> | null = null

export const handleMessage = async (message: ClientMessage, rootContext: RootContext) => {
  const { ws, connectionId } = rootContext

  const conn = connectionManager.getConnection(connectionId)

  log.trace(
    `handling message ${message.body.oneofKind} for connection ${connectionId} userId: ${conn?.userId} sessionId: ${conn?.sessionId} layer: ${conn?.layer}`,
  )

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

  const sendPong = (message: ClientMessage, nonce: bigint) => {
    sendRaw({
      id: message.id,
      body: {
        oneofKind: "pong",
        pong: {
          nonce,
        },
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
        try {
          if (!conn?.userId) {
            let _ = await handleConnectionInit(message.body.connectionInit, handlerContext)
            sendConnectionOpen()
          } else {
            log.error("connectionInit received after already authenticated")
          }
        } catch (e) {
          log.error("error handling message in connectionInit", e)
          sendRaw({
            id: message.id,
            body: { oneofKind: "connectionError", connectionError: {} },
          })
        }
        break

      case "rpcCall":
        // Import lazily to avoid circular dependency with function registry during module init.
        // Cache the promise so we only pay the dynamic import cost once.
        const { handleRpcCall } = await (rpcHandlerModulePromise ??= import("@in/server/realtime/handlers/_rpc"))
        let result = await handleRpcCall(message.body.rpcCall, handlerContext)
        sendRpcReply(result)
        break

      case "ping":
        sendPong(message, message.body.ping.nonce)
        break

      default:
        log.error("unhandled message")
        break
    }
  } catch (e) {
    const errorMeta: Record<string, unknown> = {
      connectionId,
      userId: handlerContext.userId,
      sessionId: handlerContext.sessionId,
      messageId: message.id,
      messageKind: message.body.oneofKind,
    }

    if (message.body.oneofKind === "rpcCall") {
      const call = message.body.rpcCall
      errorMeta["method"] = getMethodName(call.method)
      errorMeta["inputKind"] = call.input.oneofKind
      const input = call.input.oneofKind ? (call.input as Record<string, unknown>)[call.input.oneofKind] : undefined
      const inputIds = pickIdFields(input)
      if (inputIds) {
        errorMeta["inputIds"] = inputIds
      }
    }

    if (e instanceof RealtimeRpcError) {
      errorMeta["errorCode"] = e.code
      errorMeta["errorCodeName"] = e.codeName
      errorMeta["errorCodeNumber"] = e.codeNumber
    } else if (e instanceof InlineError) {
      errorMeta["errorType"] = e.type
      errorMeta["errorCodeNumber"] = e.code
    }

    const logMessage =
      message.body.oneofKind === "connectionInit"
        ? "error handling message in connectionInit"
        : "error handling message"
    log.error(logMessage, e, errorMeta)
    if (message.body.oneofKind === "connectionInit") {
      // TODO: handle this better
      ws.close()
    } else {
      let rpcError: RealtimeRpcError
      if (e instanceof RealtimeRpcError) {
        rpcError = e
      } else if (e instanceof InlineError) {
        rpcError = RealtimeRpcError.fromInlineError(e)
      } else {
        rpcError = RealtimeRpcError.InternalError()
      }

      sendRaw({
        id: message.id,
        body: {
          oneofKind: "rpcError",
          rpcError: {
            reqMsgId: message.id,
            errorCode: rpcError.code,
            message: rpcError.message,
            code: rpcError.codeNumber,
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

export const sendMessageToRealtimeUser = async (
  userId: number,
  payload: ServerMessage["payload"],
  options?: { skipSessionId?: number },
) => {
  const connections = connectionManager.getUserConnections(userId)

  for (let conn of connections) {
    if (options?.skipSessionId && conn.sessionId === options.skipSessionId) {
      log.debug(`skipping session ${options.skipSessionId} for user ${userId}`)
      continue
    }

    log.trace(`sending message to user ${userId} with session ${conn.sessionId} with payload ${payload}`)

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

/** Sends a message to all users in a space that are connected to the server */
export const sendMessageToRealtimeSpace = async (spaceId: number, payload: ServerMessage["payload"]) => {
  const userIds = connectionManager.getSpaceUserIds(spaceId)

  for (let userId of userIds) {
    sendMessageToRealtimeUser(userId, payload)
  }
}

export class RealtimeUpdates {
  static pushToUser(userId: number, updates: UpdatesPayload["updates"], options?: { skipSessionId?: number }) {
    sendMessageToRealtimeUser(
      userId,
      {
        oneofKind: "update",
        update: {
          updates: updates,
        },
      },
      options,
    )
  }

  static pushToSpace(spaceId: number, updates: UpdatesPayload["updates"]) {
    sendMessageToRealtimeSpace(spaceId, {
      oneofKind: "update",
      update: {
        updates: updates,
      },
    })
  }
}
