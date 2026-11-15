import {
  ConnectionError_Reason,
  Method,
  RpcCall,
  RpcError,
  RpcResult,
} from "@inline-chat/protocol/core"
import { MAX_USER_CONNECTIONS } from "@in/server/realtime/admission"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { toRealtimeRpcError } from "@in/server/realtime/rpcErrorBoundary"
import type { HandlerContext } from "@in/server/realtime/types"
import {
  getAuthTokenErrorDetails,
  getConnectionReasonFromAuthError,
  getUserIdFromToken,
} from "@in/server/modules/auth/sessionAuthentication"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { Log } from "@in/server/utils/log"

/**
 * Stateless one-shot RPC over HTTP.
 *
 * Request/response callers (the MCP server) use this instead of opening a
 * realtime socket per request. It authenticates the bearer exactly like
 * realtime `ConnectionInit` and dispatches through the same handler registry,
 * but never registers a connection: no connection-manager entry, presence,
 * repair admission, live delivery, or session client-metadata write.
 */
export const HTTP_RPC_PATH = "/v1/rpc"
export const HTTP_RPC_CONTENT_TYPE = "application/x-protobuf"
/** Set on 401s from the bearer gate so callers can tell revocation from invalid credentials. */
export const HTTP_RPC_AUTH_REASON_HEADER = "x-inline-auth-reason"
/** Ample for every allowlisted input; uploads stay on the realtime transfer path. */
export const HTTP_RPC_MAX_BODY_BYTES = 256 * 1024
/** Mirrors the realtime per-user socket cap: at most this many requests in flight per user. */
export const HTTP_RPC_MAX_IN_FLIGHT_PER_USER = MAX_USER_CONNECTIONS
export const HTTP_RPC_USER_RATE_LIMIT = { max: 600, windowMs: 60_000 }
/**
 * Failed bearer checks per client IP before the endpoint stops looking tokens
 * up. Matches the realtime per-IP upgrade budget (120/min), which today counts
 * successful connections too, so shared egress (the MCP server) is not worse off.
 */
export const HTTP_RPC_AUTH_FAILURE_LIMIT = { max: 120, windowMs: 60_000 }

/**
 * Methods that are meaningful without a socket: the reads and writes the MCP
 * server performs. Sync (GET_UPDATES*), socket-bound bot brokers, session
 * lifecycle and transfer methods are intentionally absent.
 */
export const HTTP_RPC_METHODS: ReadonlySet<Method> = new Set<Method>([
  Method.GET_ME,
  Method.GET_CHATS,
  Method.GET_SPACES,
  Method.GET_CHAT,
  Method.GET_SPACE,
  Method.GET_SPACE_MEMBERS,
  Method.GET_CHAT_PARTICIPANTS,
  Method.GET_MESSAGES,
  Method.GET_USERS,
  Method.GET_CHAT_HISTORY,
  Method.SEARCH_MESSAGES,
  Method.SEND_MESSAGE,
  Method.FORWARD_MESSAGES,
  Method.CREATE_CHAT,
  Method.CREATE_SUBTHREAD,
])

export type HttpRpcRequestOptions = {
  /** Canonical client IP resolved by the HTTP kernel. */
  clientIp: string
  nowMs?: () => number
}

const log = new Log("realtime.httpRpc")

let rpcHandlerModulePromise: Promise<typeof import("@in/server/realtime/handlers/_rpc")> | null = null

const userLimiter = new InMemoryRateLimiter({ capacity: 10_000 })
const inFlightByUser = new Map<number, number>()

type FailureWindow = { count: number; resetAtMs: number }
const authFailuresByIp = new Map<string, FailureWindow>()
const MAX_TRACKED_AUTH_FAILURE_IPS = 10_000

const protobufHeaders = (extra?: Record<string, string>): Record<string, string> => ({
  "content-type": HTTP_RPC_CONTENT_TYPE,
  "cache-control": "no-store",
  ...extra,
})

/** protobuf-ts encodes into a fresh, non-shared ArrayBuffer. */
const responseBody = (bytes: Uint8Array): Uint8Array<ArrayBuffer> => bytes as Uint8Array<ArrayBuffer>

const resultResponse = (result: RpcResult["result"]): Response =>
  new Response(responseBody(RpcResult.toBinary({ reqMsgId: 0n, result })), { status: 200, headers: protobufHeaders() })

const errorResponse = (error: RealtimeRpcError, extraHeaders?: Record<string, string>): Response => {
  const status = error.codeNumber >= 400 && error.codeNumber <= 599 ? error.codeNumber : 500
  const retryAfterSeconds = error.retryAfterSeconds ?? 0
  return new Response(
    responseBody(RpcError.toBinary({
      reqMsgId: 0n,
      errorCode: error.code,
      message: error.message,
      code: error.codeNumber,
      retryAfterSeconds,
    })),
    {
      status,
      headers: protobufHeaders({
        ...(retryAfterSeconds > 0 ? { "retry-after": String(retryAfterSeconds) } : {}),
        ...extraHeaders,
      }),
    },
  )
}

const clientError = (status: number, message: string): RealtimeRpcError =>
  new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, message, status)

const unauthenticated = (reason: ConnectionError_Reason): Response =>
  errorResponse(RealtimeRpcError.Unauthenticated(), {
    [HTTP_RPC_AUTH_REASON_HEADER]: ConnectionError_Reason[reason] ?? "UNAUTHORIZED",
    "www-authenticate": "Bearer",
  })

const bearerToken = (request: Request): string | undefined => {
  const header = request.headers.get("authorization")?.trim()
  if (!header) return undefined
  const match = /^Bearer\s+(\S+)$/i.exec(header)
  return match?.[1]
}

const authFailureRetryAfter = (ip: string, nowMs: number): number | undefined => {
  const window = authFailuresByIp.get(ip)
  if (!window) return undefined
  if (window.resetAtMs <= nowMs) {
    authFailuresByIp.delete(ip)
    return undefined
  }
  return window.count >= HTTP_RPC_AUTH_FAILURE_LIMIT.max
    ? Math.max(1, Math.ceil((window.resetAtMs - nowMs) / 1000))
    : undefined
}

const recordAuthFailure = (ip: string, nowMs: number): void => {
  const window = authFailuresByIp.get(ip)
  if (window && window.resetAtMs > nowMs) {
    window.count += 1
    return
  }
  if (!window && authFailuresByIp.size >= MAX_TRACKED_AUTH_FAILURE_IPS) {
    const oldest = authFailuresByIp.keys().next().value
    if (oldest !== undefined) authFailuresByIp.delete(oldest)
  }
  authFailuresByIp.set(ip, { count: 1, resetAtMs: nowMs + HTTP_RPC_AUTH_FAILURE_LIMIT.windowMs })
}

const isProtobufContentType = (value: string | null): boolean => {
  const mediaType = value?.split(";", 1)[0]?.trim().toLowerCase()
  return mediaType === HTTP_RPC_CONTENT_TYPE || mediaType === "application/protobuf"
}

/** Reads at most `limit` bytes; resolves undefined when the body is larger. */
const readBoundedBody = async (request: Request, limit: number): Promise<Uint8Array | undefined> => {
  const body = request.body
  if (!body) return new Uint8Array()
  const reader = body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      total += value.byteLength
      if (total > limit) {
        await reader.cancel().catch(() => {})
        return undefined
      }
      chunks.push(value)
    }
  } finally {
    reader.releaseLock()
  }
  const out = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    out.set(chunk, offset)
    offset += chunk.byteLength
  }
  return out
}

const methodName = (method: number): string => Method[method] ?? `UNKNOWN_METHOD_${method}`

export const handleHttpRpcRequest = async (request: Request, options: HttpRpcRequestOptions): Promise<Response> => {
  const nowMs = options.nowMs ?? Date.now

  const declaredLength = Number(request.headers.get("content-length") ?? "")
  if (Number.isFinite(declaredLength) && declaredLength > HTTP_RPC_MAX_BODY_BYTES) {
    return errorResponse(clientError(413, "Request body too large"))
  }

  // Token lookups cost a database read. Stop one address from spraying
  // credentials before it reaches that read; valid callers are unaffected.
  const blockedFor = authFailureRetryAfter(options.clientIp, nowMs())
  if (blockedFor !== undefined) return errorResponse(RealtimeRpcError.RateLimit(blockedFor))

  const token = bearerToken(request)
  if (!token) {
    recordAuthFailure(options.clientIp, nowMs())
    return unauthenticated(ConnectionError_Reason.INVALID_AUTH)
  }

  // Same resolution as realtime ConnectionInit: deleted users, revoked
  // sessions and user-id mismatches fail here, bots are identified, and
  // `lastActive` is touched through its existing 60 s throttle.
  let identity: Awaited<ReturnType<typeof getUserIdFromToken>>
  try {
    identity = await getUserIdFromToken(token)
  } catch (error) {
    const details = getAuthTokenErrorDetails(error)
    if (!details) {
      log.error("http rpc authentication failed", error)
      return errorResponse(RealtimeRpcError.InternalError())
    }
    recordAuthFailure(options.clientIp, nowMs())
    log.debug("http rpc authentication rejected", {
      failure: details.failure,
      credentialFingerprint: details.credentialFingerprint,
    })
    return unauthenticated(getConnectionReasonFromAuthError(error))
  }

  const rate = userLimiter.consume({ key: `http-rpc:${identity.userId}`, nowMs: nowMs(), rule: HTTP_RPC_USER_RATE_LIMIT })
  if (!rate.allowed) return errorResponse(RealtimeRpcError.RateLimit(rate.retryAfterSeconds))

  const inFlight = inFlightByUser.get(identity.userId) ?? 0
  if (inFlight >= HTTP_RPC_MAX_IN_FLIGHT_PER_USER) return errorResponse(RealtimeRpcError.RateLimit(1))
  inFlightByUser.set(identity.userId, inFlight + 1)

  let call: RpcCall | undefined
  try {
    if (!isProtobufContentType(request.headers.get("content-type"))) {
      return errorResponse(clientError(415, `Content-Type must be ${HTTP_RPC_CONTENT_TYPE}`))
    }
    const bytes = await readBoundedBody(request, HTTP_RPC_MAX_BODY_BYTES)
    if (!bytes) return errorResponse(clientError(413, "Request body too large"))

    try {
      call = RpcCall.fromBinary(bytes)
    } catch {
      return errorResponse(RealtimeRpcError.BadRequest())
    }

    if (!HTTP_RPC_METHODS.has(call.method)) {
      return errorResponse(RealtimeRpcError.UnsupportedRpcMethod(call.method))
    }

    const handlerContext: HandlerContext = {
      userId: identity.userId,
      sessionId: identity.sessionId,
      isBot: identity.isBot,
      // No socket owns this call. Handlers treat an empty id as "no connection".
      connectionId: "",
      signal: request.signal,
      sendRaw: () => {},
      sendRpcReply: () => {},
    }

    const { handleRpcCall } = await (rpcHandlerModulePromise ??= import("@in/server/realtime/handlers/_rpc"))
    const result = await handleRpcCall(call, handlerContext)
    return resultResponse(result)
  } catch (error) {
    const rpcError = toRealtimeRpcError(error)
    const meta = {
      userId: identity.userId,
      sessionId: identity.sessionId,
      method: call ? methodName(call.method) : undefined,
      errorCodeName: rpcError.codeName,
      errorCodeNumber: rpcError.codeNumber,
    }
    if (rpcError.codeNumber < 500) log.debug("http rpc rejected", { ...meta, errorMessage: rpcError.message })
    else log.error("http rpc failed", error, meta)
    return errorResponse(rpcError)
  } finally {
    const remaining = (inFlightByUser.get(identity.userId) ?? 1) - 1
    if (remaining <= 0) inFlightByUser.delete(identity.userId)
    else inFlightByUser.set(identity.userId, remaining)
  }
}

/** Test seam: clears process-local limiter state. */
export const resetHttpRpcLimitsForTests = (): void => {
  userLimiter.clear()
  inFlightByUser.clear()
  authFailuresByIp.clear()
}
