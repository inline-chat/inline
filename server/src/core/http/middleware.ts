import {
  Effect,
  Layer,
  Option,
  type Types,
} from "effect"
import { isIP } from "node:net"
import {
  HttpEffect,
  HttpMiddleware,
  HttpRouter,
  HttpServerRequest,
  HttpServerResponse,
} from "effect/unstable/http"
import {
  REQUEST_ID_HEADER,
  generateRequestId,
  resolveRequestId,
  type RequestId,
} from "../helpers/requestId"
import {
  HttpRequestContext,
  requestPath,
  type HttpRequestContextShape,
} from "./requestContext"
import {
  HttpRateLimiter,
  type HttpRateLimiterOptions,
  type HttpRateLimiterShape,
  httpRateLimitErrorBody,
  makeHttpRateLimiterLayer,
  type HttpRateLimitPermit,
} from "./rateLimit"
import { usesLegacySetupMiddleware } from "./legacySetupCompatibility"

export const CORS_ORIGINS = [
  "https://inline.chat",
  "https://app.inline.chat",
  "https://admin.inline.chat",
  "https://mcp.inline.chat",
  "http://localhost:8001",
  "http://localhost:5174",
  "http://127.0.0.1:5174",
] as const

export const CORS_ALLOWED_HEADERS = [
  "accept",
  "authorization",
  "content-type",
  "mcp-protocol-version",
  "x-inline-mcp-secret",
  REQUEST_ID_HEADER,
] as const

export const CORS_EXPOSED_HEADERS = [
  REQUEST_ID_HEADER,
  "ratelimit-limit",
  "ratelimit-remaining",
  "ratelimit-reset",
  "retry-after",
  "x-ratelimit-limit",
  "x-ratelimit-remaining",
  "x-ratelimit-reset",
] as const

const commonSecurityHeaders = {
  "cross-origin-opener-policy": "same-origin",
  "cross-origin-resource-policy": "cross-origin",
  "origin-agent-cluster": "?1",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
  "x-dns-prefetch-control": "off",
  "x-download-options": "noopen",
  "x-frame-options": "SAMEORIGIN",
  "x-permitted-cross-domain-policies": "none",
} as const

export interface HttpKernelMiddlewareOptions {
  /**
   * One proxy-owned header that is overwritten with a single client IP.
   *
   * This is deliberately not a blanket "trust proxy" switch: no fallback
   * forwarding headers are considered, and malformed values fall back to the
   * direct peer address.
   */
  readonly clientIpHeader?: TrustedClientIpHeader | undefined
  readonly isProduction: boolean
  readonly generateRequestId?: (() => RequestId) | undefined
  readonly nowMillis?: (() => number) | undefined
  readonly rateLimit?: HttpRateLimiterOptions | undefined
}

export type TrustedClientIpHeader =
  | "cf-connecting-ip"
  | "x-real-ip"

export const parseTrustedClientIpHeader = (
  input: string | undefined,
): TrustedClientIpHeader | undefined => {
  const value = input?.trim().toLowerCase()
  if (value === undefined || value === "") {
    return undefined
  }
  if (value === "cf-connecting-ip" || value === "x-real-ip") {
    return value
  }

  throw new Error(
    "INLINE_TRUSTED_CLIENT_IP_HEADER must be cf-connecting-ip or x-real-ip.",
  )
}

const responseHeaders = (
  context: HttpRequestContextShape,
  isProduction: boolean,
): Record<string, string> => ({
  ...commonSecurityHeaders,
  ...(isProduction
    ? { "strict-transport-security": "max-age=31536000; includeSubDomains" }
    : {}),
  [REQUEST_ID_HEADER]: context.requestId,
})

const makeKernelMiddleware = ({
  clientIpHeader,
  isProduction,
  generateRequestId: generate = generateRequestId,
  nowMillis = Date.now,
}: HttpKernelMiddlewareOptions): (<E, R>(
  httpApp: Effect.Effect<
    HttpServerResponse.HttpServerResponse,
    E,
    R
  >,
) => Effect.Effect<
  HttpServerResponse.HttpServerResponse,
  E,
  HttpServerRequest.HttpServerRequest | Exclude<R, HttpRequestContext>
>) =>
  HttpMiddleware.make((httpApp) =>
    Effect.gen(function* () {
      const request = yield* HttpServerRequest.HttpServerRequest
      const context: HttpRequestContextShape = {
        clientIp: resolveClientIp(request, clientIpHeader),
        requestId: resolveRequestId(
          request.headers[REQUEST_ID_HEADER],
          generate,
        ),
        method: request.method,
        path: requestPath(request.url),
        startedAtMillis: nowMillis(),
      }

      HttpEffect.appendPreResponseHandlerUnsafe(
        request,
        (
          _request: HttpServerRequest.HttpServerRequest,
          response: HttpServerResponse.HttpServerResponse,
        ) =>
          Effect.succeed(
            HttpServerResponse.setHeaders(
              response,
              responseHeaders(context, isProduction),
            ),
          ),
      )

      return yield* httpApp.pipe(
        Effect.provideService(HttpRequestContext, context),
        Effect.annotateLogs({
          "http.method": context.method,
          "http.path": context.path,
          "http.request_id": context.requestId,
        }),
      )
    }),
  )

const rateLimitHeaders = (
  permit: HttpRateLimitPermit,
  exceeded: boolean,
): Record<string, string> => ({
  "ratelimit-limit": String(permit.limit),
  "ratelimit-remaining": String(permit.remaining),
  "ratelimit-reset": String(permit.resetSeconds),
  ...(exceeded
    ? { "retry-after": String(permit.resetSeconds) }
    : {}),
})

const headerValue = (
  request: HttpServerRequest.HttpServerRequest,
  name: string,
): string | undefined => {
  const value = request.headers[name]?.trim()
  return value === "" ? undefined : value
}

const validIpAddress = (
  value: string | undefined,
): string | undefined =>
  value !== undefined && isIP(value) !== 0 ? value : undefined

export const UNRESOLVED_CLIENT_IP = "unresolved-client"

export const resolveClientIp = (
  request: HttpServerRequest.HttpServerRequest,
  clientIpHeader: TrustedClientIpHeader | undefined,
): string => {
  const proxyAddress = clientIpHeader === undefined
    ? undefined
    : validIpAddress(headerValue(request, clientIpHeader))
  const peerAddress = validIpAddress(
    Option.getOrUndefined(request.remoteAddress),
  )

  // Keep the fallback stable. A request-scoped fallback would let a client
  // bypass the limiter whenever neither address source is usable.
  return proxyAddress ?? peerAddress ?? UNRESOLVED_CLIENT_IP
}

const makeRateLimitMiddleware = (
  limiter: HttpRateLimiterShape,
) =>
  <E, R>(
    httpApp: Effect.Effect<
      HttpServerResponse.HttpServerResponse,
      E,
      R
    >,
  ): Effect.Effect<
    HttpServerResponse.HttpServerResponse,
    E,
    | R
    | HttpRequestContext
    | HttpServerRequest.HttpServerRequest
  > =>
    Effect.gen(function* () {
      const request = yield* HttpServerRequest.HttpServerRequest
      const context = yield* HttpRequestContext
      if (!usesLegacySetupMiddleware(context.path)) {
        return yield* httpApp
      }
      const key = context.clientIp
      return yield* Effect.matchEffect(
        limiter.consume(key),
        {
          onFailure: (error) =>
            Effect.succeed(
              HttpServerResponse.jsonUnsafe(httpRateLimitErrorBody, {
                status: 420,
                headers: rateLimitHeaders(error, true),
              }),
            ),
          onSuccess: (permit) => {
            HttpEffect.appendPreResponseHandlerUnsafe(
              request,
              (
                _request: HttpServerRequest.HttpServerRequest,
                response: HttpServerResponse.HttpServerResponse,
              ) =>
                // Preserve the current plugin's countFailedRequest=false
                // behavior. Its not-found hook still counts unmatched paths.
                (response.status >= 400 && response.status !== 404
                  ? limiter.refund(key)
                  : Effect.void
                ).pipe(
                  Effect.as(
                    HttpServerResponse.setHeaders(
                      response,
                      rateLimitHeaders(permit, false),
                    ),
                  ),
                ),
            )

            return httpApp
          },
        },
      )
    })

type KernelHttpMiddleware = <E, R>(
  httpApp: Effect.Effect<
    HttpServerResponse.HttpServerResponse,
    E,
    R
  >,
) => Effect.Effect<
  HttpServerResponse.HttpServerResponse,
  E,
  | HttpServerRequest.HttpServerRequest
  | Exclude<R, HttpRequestContext>
>

const makeCombinedMiddleware = (
  options: HttpKernelMiddlewareOptions,
  limiter: HttpRateLimiterShape,
): KernelHttpMiddleware => {
  const corsMiddleware = HttpMiddleware.cors({
    allowedOrigins: CORS_ORIGINS,
    credentials: true,
    allowedMethods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allowedHeaders: CORS_ALLOWED_HEADERS,
    exposedHeaders: CORS_EXPOSED_HEADERS,
    maxAge: 86_400,
  })
  const kernelMiddleware = makeKernelMiddleware(options)
  const rateLimitMiddleware = makeRateLimitMiddleware(
    limiter,
  )

  return HttpMiddleware.make((httpApp) =>
    kernelMiddleware(
      corsMiddleware(
        rateLimitMiddleware(httpApp),
      ),
    ),
  )
}

type InstalledKernelMiddleware = (
  httpApp: Effect.Effect<
    HttpServerResponse.HttpServerResponse,
    Types.unhandled,
    HttpRequestContext
  >,
) => Effect.Effect<
  HttpServerResponse.HttpServerResponse,
  Types.unhandled,
  HttpServerRequest.HttpServerRequest
>

/**
 * Global middleware for the replacement HTTP root.
 *
 * The request-context wrapper stays outside CORS so request IDs and security
 * headers are also attached to preflight, fallback, and failure responses.
 */
export const makeHttpKernelMiddlewareLayer = (
  options: HttpKernelMiddlewareOptions,
) => {
  const middleware: Effect.Effect<
    InstalledKernelMiddleware,
    never,
    HttpRateLimiter
  > = HttpRateLimiter.use((limiter) =>
      Effect.succeed(
        makeCombinedMiddleware(options, limiter),
      ),
    )

  return HttpRouter.middleware<{ provides: HttpRequestContext }>()(
    middleware,
    { global: true },
  ).pipe(
    Layer.provide(
      makeHttpRateLimiterLayer({
        ...options.rateLimit,
        nowMillis: options.rateLimit?.nowMillis ?? options.nowMillis,
      }),
    ),
  )
}
