import { admitPreauthMessage } from "./admission"
import { connectionManager } from "@in/server/ws/connections"
import {
  ClientMessage,
  ConnectionError_Reason,
  type CreateChatInput,
  Method,
  RpcResult,
  ServerMessage,
  ServerProtocolMessage,
  UpdatesPayload,
} from "@inline-chat/protocol/core"
import type { HandlerContext, RootContext, Ws } from "./types"
import { handleConnectionInit } from "@in/server/realtime/handlers/_connectionInit"
import { Log } from "@in/server/utils/log"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { toRealtimeRpcError } from "@in/server/realtime/rpcErrorBoundary"
import { InlineError } from "@in/server/types/errors"
import {
  getAuthTokenErrorDetails,
  getConnectionReasonFromAuthError,
} from "@in/server/modules/auth/sessionAuthentication"
import { BoundedLogAggregator } from "@in/server/utils/logging/boundedLogAggregator"
import { db } from "@in/server/db"
import { members, spaces, users } from "@in/server/db/schema"
import { and, eq, inArray, isNull, or } from "drizzle-orm"

const log = new Log("realtime")
const MAX_SPACE_AUTHORIZATION_RECIPIENTS_PER_QUERY = 512
const MAX_CONCURRENT_SPACE_DELIVERIES = 32

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

export const createChatRejectionMetadata = (
  input: CreateChatInput,
  rpcError: RealtimeRpcError,
): Record<string, string | number | boolean> => ({
  event: "realtime.create_chat.rejected",
  method: getMethodName(Method.CREATE_CHAT),
  errorCodeName: rpcError.codeName,
  errorCodeNumber: rpcError.codeNumber,
  hasReservedChatId: input.reservedChatId !== undefined,
  destination: input.spaceId === undefined ? "home" : "space",
  visibility: input.isPublic ? "public" : "private",
  participantCount: input.participants.length,
  hasAgentContext: input.agentContext !== undefined,
  hasAgentId: input.agentContext?.agentId !== undefined,
  hasConfiguration: input.agentContext?.configuration !== undefined,
  hasProject: input.agentContext?.configuration?.projectId !== undefined,
  hasModel: input.agentContext?.configuration?.modelId !== undefined,
  hasReasoning: input.agentContext?.configuration?.reasoningEffortId !== undefined,
})

const AUTH_REJECTION_WARNING_WINDOW_MS = 15 * 60 * 1000
const authRejectionLogs = new BoundedLogAggregator(AUTH_REJECTION_WARNING_WINDOW_MS, 1_024)

const connectionReasonName = (reason: ConnectionError_Reason): string => {
  return ConnectionError_Reason[reason] ?? `UNKNOWN_CONNECTION_REASON_${reason}`
}

const cleanLogValue = (value: string | null | undefined): string | undefined => {
  const trimmed = value?.trim()
  if (!trimmed) return undefined
  return trimmed.length > 200 ? `${trimmed.slice(0, 200)}...` : trimmed
}

const connectionInitRejectionMetadata = (
  message: ClientMessage,
  rootContext: RootContext,
  error: unknown,
  reason: ConnectionError_Reason,
): Record<string, unknown> => {
  const init = message.body.oneofKind === "connectionInit" ? message.body.connectionInit : undefined
  const inlineError = error instanceof InlineError ? error : undefined

  return {
    event: "realtime.connection_init.rejected",
    connectionId: rootContext.connectionId,
    messageId: message.id.toString(),
    seq: message.seq,
    ...rootContext.requestMetadata,
    layer: init?.layer,
    buildNumber: init?.buildNumber,
    clientVersion: cleanLogValue(init?.clientVersion),
    osVersion: cleanLogValue(init?.osVersion),
    apiError: inlineError?.type,
    errorCode: inlineError?.code,
    connectionReason: connectionReasonName(reason),
    connectionReasonCode: reason,
    ...getAuthTokenErrorDetails(error),
  }
}

// Cache for lazily-loaded RPC handler to avoid circular import and per-call dynamic import cost
let rpcHandlerModulePromise: Promise<typeof import("@in/server/realtime/handlers/_rpc")> | null = null

export const handleMessage = async (message: ClientMessage, rootContext: RootContext) => {
  const { ws, connectionId } = rootContext

  const conn = connectionManager.getConnection(connectionId)
  // This only marks in-memory, per-session activity. Presence batches the
  // durable touch, so authenticated frames never add a database query here.
  connectionManager.markConnectionActivity(connectionId)

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
    isBot: conn?.isBot ?? false,
    connectionId,
    sendRaw,
    sendRpcReply,
  }

  const releaseAdmission = admitPreauthMessage(conn ?? ws, Boolean(conn?.userId), message.body.oneofKind === "connectionInit")
  if (!releaseAdmission) { ws.close(); return }
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
          const reason = getConnectionReasonFromAuthError(e)
          const authDetails = getAuthTokenErrorDetails(e)
          const metadata = connectionInitRejectionMetadata(message, rootContext, e, reason)
          if (authDetails) {
            const isExpectedLifecycleFailure =
              authDetails.failure === "user_deactivated" ||
              authDetails.failure === "session_revoked"
            const decision = isExpectedLifecycleFailure
              ? { emit: false, suppressedCount: 0 }
              : authRejectionLogs.record(
                `${authDetails.failure}:${authDetails.credentialFingerprint ?? "unknown"}`,
              )
            const rejectionMetadata = decision.suppressedCount > 0
              ? { ...metadata, suppressedCount: decision.suppressedCount }
              : metadata
            if (decision.emit) {
              log.warn("realtime connectionInit rejected", rejectionMetadata)
            } else {
              log.debug("realtime connectionInit rejected", rejectionMetadata)
            }
          } else {
            log.error("error handling message in connectionInit", e, metadata)
          }
          sendRaw({
            id: message.id,
            body: { oneofKind: "connectionError", connectionError: { reason } },
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

      case "ack":
        break

      default:
        log.warn("realtime unsupported client message", {
          connectionId,
          messageId: message.id.toString(),
          seq: message.seq,
          messageKind: message.body.oneofKind ?? "unknown",
          layer: conn?.layer,
        })
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

    const rpcError = toRealtimeRpcError(e)

    if (message.body.oneofKind === "rpcCall" && rpcError.codeNumber < 500) {
      const call = message.body.rpcCall
      if (call.method === Method.CREATE_CHAT && call.input.oneofKind === "createChat") {
        log.warn(
          "realtime createChat rejected",
          createChatRejectionMetadata(call.input.createChat, rpcError),
        )
      } else {
        log.debug("realtime RPC rejected", {
          ...errorMeta,
          errorMessage: rpcError.message,
        })
      }
    } else {
      const logMessage =
        message.body.oneofKind === "connectionInit"
          ? "error handling message in connectionInit"
          : "error handling message"
      log.error(logMessage, e, errorMeta)
    }
    if (message.body.oneofKind === "connectionInit") {
      // TODO: handle this better
      ws.close()
    } else {
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
  } finally {
    releaseAdmission()
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

/**
 * Bun returns 0 only when it drops a frame. A negative result means the
 * frame was accepted with backpressure, so it remains a successful transport
 * handoff. This is deliberately not a client acknowledgement: durable repair
 * still discovers and replays missed updates independently.
 */
const sendRaw = (ws: Ws, message: ServerProtocolMessage): boolean => {
  return ws.raw.sendBinary(ServerProtocolMessage.toBinary(message), true) !== 0
}

/**
 * Internal delivery primitive for callers that must distinguish a current
 * transport acceptance from a frame rejected by Bun. It is still not a client
 * acknowledgement and does not authorize against the database.
 */
export const sendMessageToRealtimeUserWithDelivery = async (
  userId: number,
  payload: ServerMessage["payload"],
  options?: { skipSessionId?: number },
) => {
  const connections = connectionManager.getUserConnections(userId)
  let accepted = 0
  for (let conn of connections) {
    if (options?.skipSessionId && conn.sessionId === options.skipSessionId) {
      log.debug(`skipping session ${options.skipSessionId} for user ${userId}`)
      continue
    }

    log.trace(`sending message to user ${userId} with session ${conn.sessionId} with payload ${payload}`)

    const id = genId()
    if (sendRaw(conn.ws, {
      id,
      body: {
        oneofKind: "message",
        message: { payload },
      },
    })) {
      accepted += 1
    } else {
      // A frame rejected by the transport cannot be repaired through this
      // socket. Remove it so a positive result covers every live survivor.
      connectionManager.closeConnection(conn.connectionId)
    }
  }
  return accepted
}

/** Preserves the established fire-and-forget realtime API for ordinary fanout. */
export const sendMessageToRealtimeUser = async (
  userId: number,
  payload: ServerMessage["payload"],
  options?: { skipSessionId?: number },
): Promise<void> => {
  await sendMessageToRealtimeUserWithDelivery(userId, payload, options)
}

/** Sends an ephemeral event only to connections authenticated as this bot. */
export const sendMessageToRealtimeBot = async (
  botUserId: number,
  payload: ServerMessage["payload"],
): Promise<number> => {
  const connections = connectionManager
    .getUserConnections(botUserId)
    .filter((connection) => connection.isBot === true)
  if (connections.length === 0) return 0

  const id = genId()
  let accepted = 0
  for (const connection of connections) {
    if (sendRaw(connection.ws, {
      id,
      body: {
        oneofKind: "message",
        message: { payload },
      },
    })) {
      accepted += 1
    } else {
      connectionManager.closeConnection(connection.connectionId)
    }
  }
  return accepted
}

/** Selects one exact authenticated bot socket for a private request/reply flow. */
export const getRealtimeBotConnection = (
  botUserId: number,
): { connectionId: string; sessionId: number } | undefined => {
  const connection = connectionManager
    .getUserConnections(botUserId)
    .find((candidate) => candidate.isBot === true && candidate.sessionId !== undefined)
  if (!connection?.sessionId) return undefined
  return { connectionId: connection.connectionId, sessionId: connection.sessionId }
}

/** Sends private material only to the exact authenticated bot socket selected above. */
export const sendMessageToRealtimeBotConnection = async (
  botUserId: number,
  connectionId: string,
  payload: ServerMessage["payload"],
): Promise<boolean> => {
  const connection = connectionManager.getConnection(connectionId)
  if (connection?.userId !== botUserId || connection.isBot !== true) return false

  const accepted = sendRaw(connection.ws, {
    id: genId(),
    body: {
      oneofKind: "message",
      message: { payload },
    },
  })
  if (!accepted) connectionManager.closeConnection(connection.connectionId)
  return accepted
}

/**
 * Sends session-scoped material only to sockets authenticated by the exact app
 * session. A user may have several active sessions, and one session may own
 * more than one socket during reconnect overlap, so neither a user-wide send
 * nor a single-connection lookup is sufficient for Grid credentials.
 */
export const sendMessageToRealtimeSession = async (
  userId: number,
  sessionId: number,
  payload: ServerMessage["payload"],
) => {
  const connections = connectionManager
    .getUserConnections(userId)
    .filter((connection) => connection.sessionId === sessionId)
  const id = genId()

  let accepted = 0
  for (const connection of connections) {
    log.trace(`sending message to user ${userId} with exact session ${sessionId} with payload ${payload}`)
    if (sendRaw(connection.ws, {
      id,
      body: {
        oneofKind: "message",
        message: { payload },
      },
    })) {
      accepted += 1
    } else {
      connectionManager.closeConnection(connection.connectionId)
    }
  }
  return accepted
}

/**
 * Sends a message to all locally connected current members of a space.
 *
 * The process-local membership index only narrows the candidates. Every
 * batch is re-authorized from the database so a departed member, a deleted
 * account, or a deleted space cannot receive a realtime frame from a stale
 * index. The bounded batches also keep a large space from creating one
 * oversized `IN (...)` query.
 */
export const sendMessageToRealtimeSpace = async (spaceId: number, payload: ServerMessage["payload"]) => {
  const userIds = connectionManager.getSpaceUserIds(spaceId)
  if (userIds.length === 0) return
  const deliveryErrors: unknown[] = []
  for (let offset = 0; offset < userIds.length; offset += MAX_SPACE_AUTHORIZATION_RECIPIENTS_PER_QUERY) {
    const candidates = userIds.slice(offset, offset + MAX_SPACE_AUTHORIZATION_RECIPIENTS_PER_QUERY)
    const authorized = await db.select({ userId: members.userId }).from(members)
      .innerJoin(spaces, eq(spaces.id, members.spaceId))
      .innerJoin(users, eq(users.id, members.userId))
      .where(and(
        eq(members.spaceId, spaceId),
        inArray(members.userId, candidates),
        isNull(spaces.deleted),
        // The historical nullable column uses NULL/false for active accounts.
        or(isNull(users.deleted), eq(users.deleted, false)),
      ))
    for (let deliveryOffset = 0; deliveryOffset < authorized.length; deliveryOffset += MAX_CONCURRENT_SPACE_DELIVERIES) {
      const deliveries = await Promise.allSettled(authorized
        .slice(deliveryOffset, deliveryOffset + MAX_CONCURRENT_SPACE_DELIVERIES)
        .map(({ userId }) => sendMessageToRealtimeUserWithDelivery(userId, payload)))
      for (const delivery of deliveries) {
        if (delivery.status === "rejected") deliveryErrors.push(delivery.reason)
      }
    }
  }
  if (deliveryErrors.length > 0) throw new AggregateError(deliveryErrors, "Space realtime delivery failed")
}

export class RealtimeUpdates {
  /** Provides the transport signal for durable-repair only. */
  static pushToUserWithDelivery(userId: number, updates: UpdatesPayload["updates"], options?: { skipSessionId?: number }): Promise<number> {
    return sendMessageToRealtimeUserWithDelivery(
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

  /** Ordinary callers intentionally do not observe frame acceptance. */
  static async pushToUser(userId: number, updates: UpdatesPayload["updates"], options?: { skipSessionId?: number }): Promise<void> {
    await this.pushToUserWithDelivery(userId, updates, options)
  }

  static pushToSpace(spaceId: number, updates: UpdatesPayload["updates"]) {
    return sendMessageToRealtimeSpace(spaceId, {
      oneofKind: "update",
      update: {
        updates: updates,
      },
    })
  }
}
