import { Context } from "effect"
import type { HttpMethod } from "effect/unstable/http/HttpMethod"
import type { RequestId } from "../helpers/requestId"

export interface HttpRequestContextShape {
  /**
   * Canonical request identity resolved once from the configured proxy-owned
   * header, the direct transport peer, or a stable fallback.
   */
  readonly clientIp: string
  readonly requestId: RequestId
  readonly method: HttpMethod
  /** Request path without a query string or fragment. */
  readonly path: string
  readonly startedAtMillis: number
}

/**
 * Request-scoped metadata shared by replacement HTTP handlers.
 *
 * Authentication and authorization state deliberately live in their own
 * capabilities so this context stays cheap and safe to attach to every request.
 */
export class HttpRequestContext extends Context.Service<
  HttpRequestContext,
  HttpRequestContextShape
>()("@inline/server/core/http/HttpRequestContext") {}

export const requestPath = (url: string): string => {
  const queryIndex = url.indexOf("?")
  const hashIndex = url.indexOf("#")

  if (queryIndex === -1) {
    return hashIndex === -1 ? url : url.slice(0, hashIndex)
  }
  if (hashIndex === -1) {
    return url.slice(0, queryIndex)
  }
  return url.slice(0, Math.min(queryIndex, hashIndex))
}
