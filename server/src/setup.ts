import Elysia from "elysia"
import cors from "@elysiajs/cors"
import { ApiError, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { rateLimit } from "elysia-rate-limit"
import { nanoid } from "nanoid/non-secure"
import { getIp } from "@in/server/utils/ip"
import { isProd } from "@in/server/env"

const REQUEST_ID_HEADER = "x-request-id"
const MAX_REQUEST_ID_LENGTH = 128
const REQUEST_ID_PATTERN = /^[a-zA-Z0-9._-]+$/
const CORS_ORIGINS = [
  "https://inline.chat",
  "https://app.inline.chat",
  "https://admin.inline.chat",
  "https://mcp.inline.chat",
  "http://localhost:8001",
  "http://localhost:5174",
  "http://127.0.0.1:5174",
]

const CORS_ALLOWED_HEADERS = [
  "accept",
  "authorization",
  "content-type",
  "mcp-protocol-version",
  "x-inline-mcp-secret",
  REQUEST_ID_HEADER,
]

const CORS_EXPOSED_HEADERS = [
  REQUEST_ID_HEADER,
  "ratelimit-limit",
  "ratelimit-remaining",
  "ratelimit-reset",
  "retry-after",
  "x-ratelimit-limit",
  "x-ratelimit-remaining",
  "x-ratelimit-reset",
]

const getRequestId = (request: Request) => {
  const raw = request.headers.get(REQUEST_ID_HEADER)
  if (raw) {
    const value = raw.trim()
    if (value.length > 0 && value.length <= MAX_REQUEST_ID_LENGTH && REQUEST_ID_PATTERN.test(value)) {
      return value
    }
  }

  return nanoid()
}

const setSecurityHeaders = (set: { headers: Record<string, string> }) => {
  set.headers["X-Content-Type-Options"] = "nosniff"
  set.headers["X-Frame-Options"] = "SAMEORIGIN"
  set.headers["Referrer-Policy"] = "no-referrer"
  set.headers["X-DNS-Prefetch-Control"] = "off"
  set.headers["X-Download-Options"] = "noopen"
  set.headers["X-Permitted-Cross-Domain-Policies"] = "none"
  set.headers["Cross-Origin-Opener-Policy"] = "same-origin"
  set.headers["Cross-Origin-Resource-Policy"] = "cross-origin"
  set.headers["Origin-Agent-Cluster"] = "?1"

  if (isProd) {
    set.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
  }
}

// Composed of various plugins to be used as a Service Locator
export const setup = new Elysia({ name: "setup" })
  .state("requestId", "")
  .onRequest(({ request, set, store }) => {
    const requestId = getRequestId(request)
    store.requestId = requestId
    set.headers[REQUEST_ID_HEADER] = requestId
    setSecurityHeaders(set)
  })
  // setup cors
  .use(
    cors({
      origin: CORS_ORIGINS,
      credentials: true,
      methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
      allowedHeaders: CORS_ALLOWED_HEADERS,
      exposeHeaders: CORS_EXPOSED_HEADERS,
      maxAge: 86400,
    }),
  )
  .use(
    rateLimit({
      max: 100,
      scoping: "global",
      generator: (request, server) => {
        let ip = getIp(request, server) ?? nanoid()

        const isValidIp = (ip: string) => {
          return ip !== "::" && !ip.startsWith(":::")
        }

        if (!isValidIp(ip)) {
          Log.shared.warn("Invalid IP", ip)
          ip = nanoid() // Assign a random ID if the IP is invalid
        }

        return ip
      },
      errorResponse: new InlineError(ApiError.FLOOD).asApiResponse(),
    }),
  )
  .error("INLINE_ERROR", InlineError)
// .onError(({ code, error }) => {
//   Log.shared.error("Top level error " + code, error)
//   // TODO: Return something
// })
