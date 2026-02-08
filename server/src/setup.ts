import Elysia from "elysia"
import cors from "@elysiajs/cors"
import { helmet } from "elysia-helmet"
import { ApiError, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { rateLimit } from "elysia-rate-limit"
import { nanoid } from "nanoid/non-secure"

const REQUEST_ID_HEADER = "x-request-id"
const MAX_REQUEST_ID_LENGTH = 128
const REQUEST_ID_PATTERN = /^[a-zA-Z0-9._-]+$/

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

// Composed of various plugins to be used as a Service Locator
export const setup = new Elysia({ name: "setup" })
  .state("requestId", "")
  .onRequest(({ request, set, store }) => {
    const requestId = getRequestId(request)
    store.requestId = requestId
    set.headers[REQUEST_ID_HEADER] = requestId
    Log.shared.debug("request", {
      requestId,
      method: request.method,
      url: request.url,
    })
  })
  // setup cors
  .use(
    cors({
      origin: [
        "https://inline.chat",
        "https://app.inline.chat",
        "https://admin.inline.chat",
        "http://localhost:8001",
        "http://localhost:5174",
        "http://127.0.0.1:5174",
      ],
      credentials: true,
    }),
  )
  .use(
    rateLimit({
      max: 100,
      scoping: "global",
      generator: (request, server) => {
        let ip =
          request.headers.get("x-forwarded-for") ??
          request.headers.get("cf-connecting-ip") ??
          request.headers.get("x-real-ip") ??
          server?.requestIP(request)?.address ??
          // avoid stopping the server if failed to get ip
          nanoid()

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
  .use(
    helmet({
      // fix later
      contentSecurityPolicy: false,
    }),
  )
  .error("INLINE_ERROR", InlineError)
// .onError(({ code, error }) => {
//   Log.shared.error("Top level error " + code, error)
//   // TODO: Return something
// })
