import { InlineSdkAuthenticationError, ProtocolClientError } from "@inline-chat/realtime-sdk"
import { ConnectionError_Reason, Method, RpcCall, RpcError, RpcResult } from "@inline-chat/protocol/core"
import { READ_ONLY_RPC_METHODS } from "@inline-chat/protocol/transfers"

export type InlineRpcCallOptions = {
  signal?: AbortSignal
  /** Overrides the invoker default; null disables the deadline. */
  timeoutMs?: number | null
}

/**
 * One request/response RPC. Implementations reject with the same error
 * classes the realtime SDK uses (`ProtocolClientError`,
 * `InlineSdkAuthenticationError`, abort reasons) so tool error mapping does
 * not depend on the transport.
 */
export type InlineRpcInvoker = {
  invoke(method: Method, input: RpcCall["input"], options?: InlineRpcCallOptions): Promise<RpcResult["result"]>
}

export const INLINE_RPC_PATH = "/v1/rpc"
export const INLINE_RPC_CONTENT_TYPE = "application/x-protobuf"
export const INLINE_RPC_AUTH_REASON_HEADER = "x-inline-auth-reason"
/** Same default deadline as the SDK's realtime RPCs. */
export const DEFAULT_INLINE_RPC_TIMEOUT_MS = 30_000

/** Mirrors the SDK reconnect policy: these may be retried without a duplicate effect. */
const isReplaySafe = (method: Method, input: RpcCall["input"]): boolean => {
  if (method === Method.SEND_MESSAGE && input.oneofKind === "sendMessage") {
    return input.sendMessage.randomId !== undefined && input.sendMessage.randomId !== 0n
  }
  return READ_ONLY_RPC_METHODS.has(method)
}

const authenticationError = (reason: string | null): InlineSdkAuthenticationError => {
  switch (reason) {
    case "INVALID_AUTH":
      return new InlineSdkAuthenticationError("INVALID_AUTH", ConnectionError_Reason.INVALID_AUTH)
    case "SESSION_REVOKED":
      return new InlineSdkAuthenticationError("SESSION_REVOKED", ConnectionError_Reason.SESSION_REVOKED)
    default:
      return new InlineSdkAuthenticationError("UNAUTHORIZED", ConnectionError_Reason.UNAUTHORIZED)
  }
}

const normalizeBaseUrl = (baseUrl: string): string => {
  const url = new URL(baseUrl)
  url.pathname = url.pathname.replace(/\/+$/, "") || "/"
  return url.toString().replace(/\/$/, "")
}

const isProtobuf = (response: Response): boolean =>
  response.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase() === INLINE_RPC_CONTENT_TYPE

const abortReason = (signal: AbortSignal): Error =>
  signal.reason instanceof Error ? signal.reason : new DOMException("The operation was aborted", "AbortError")

/**
 * Stateless HTTP transport for Inline RPC (`POST /v1/rpc`). Each call is one
 * authenticated request; the server keeps no connection, presence, or sync
 * state for it.
 */
export function createHttpRpcInvoker(params: {
  baseUrl: string
  token: string
  fetch?: typeof fetch
  timeoutMs?: number | null
}): InlineRpcInvoker {
  const endpoint = `${normalizeBaseUrl(params.baseUrl)}${INLINE_RPC_PATH}`
  const fetchImpl = params.fetch ?? fetch
  const defaultTimeoutMs = params.timeoutMs === undefined ? DEFAULT_INLINE_RPC_TIMEOUT_MS : params.timeoutMs

  return {
    async invoke(method, input, options) {
      const callerSignal = options?.signal
      callerSignal?.throwIfAborted()
      const replaySafe = isReplaySafe(method, input)
      const timeoutMs = options?.timeoutMs === undefined ? defaultTimeoutMs : options.timeoutMs
      const controller = new AbortController()
      let timedOut = false
      const timer = timeoutMs != null && Number.isFinite(timeoutMs) && timeoutMs > 0
        ? setTimeout(() => {
          timedOut = true
          controller.abort()
        }, Math.floor(timeoutMs))
        : undefined
      const onCallerAbort = () => controller.abort()
      callerSignal?.addEventListener("abort", onCallerAbort, { once: true })

      const failure = (error: unknown): Error => {
        if (callerSignal?.aborted) return abortReason(callerSignal)
        if (timedOut) {
          return replaySafe
            ? new ProtocolClientError("timeout")
            : new ProtocolClientError("commit-outcome-unknown", { message: "RPC timed out after dispatch" })
        }
        const detail = error instanceof Error ? error.message : String(error)
        return replaySafe
          ? new ProtocolClientError("not-connected", { message: `Inline RPC transport failed: ${detail}` })
          : new ProtocolClientError("commit-outcome-unknown", { message: `Inline RPC transport failed after dispatch: ${detail}` })
      }

      try {
        // Encoding failures are local programming errors, never transport outcomes.
        const requestBody = RpcCall.toBinary(RpcCall.create({ method, input })) as Uint8Array<ArrayBuffer>
        let response: Response
        let body: Uint8Array
        try {
          response = await fetchImpl(endpoint, {
            method: "POST",
            headers: {
              authorization: `Bearer ${params.token}`,
              "content-type": INLINE_RPC_CONTENT_TYPE,
              accept: INLINE_RPC_CONTENT_TYPE,
            },
            body: requestBody,
            signal: controller.signal,
          })
          body = new Uint8Array(await response.arrayBuffer())
        } catch (error) {
          throw failure(error)
        }

        if (response.ok) {
          if (!isProtobuf(response)) throw failure(new Error(`unexpected response type for HTTP ${response.status}`))
          let result: RpcResult["result"]
          try {
            result = RpcResult.fromBinary(body).result
          } catch {
            throw failure(new Error("undecodable RpcResult"))
          }
          if (input.oneofKind !== undefined && result.oneofKind !== input.oneofKind) {
            throw new Error(`rpc result mismatch: method ${Method[method]} expects ${input.oneofKind}`)
          }
          return result
        }

        if (response.status === 401 && response.headers.has(INLINE_RPC_AUTH_REASON_HEADER)) {
          throw authenticationError(response.headers.get(INLINE_RPC_AUTH_REASON_HEADER))
        }

        if (isProtobuf(response)) {
          let rpcError: RpcError | undefined
          try { rpcError = RpcError.fromBinary(body) } catch { rpcError = undefined }
          if (rpcError) {
            throw new ProtocolClientError("rpc-error", {
              code: rpcError.code,
              message: rpcError.message,
              retryAfterSeconds: rpcError.retryAfterSeconds,
            })
          }
        }
        // A proxy or gateway answered instead of Inline (or the route is not
        // deployed): the call may or may not have executed.
        throw failure(new Error(`HTTP ${response.status}`))
      } finally {
        if (timer) clearTimeout(timer)
        callerSignal?.removeEventListener("abort", onCallerAbort)
      }
    },
  }
}
