import Elysia from "elysia"
import cors from "@elysiajs/cors"
import { helmet } from "elysia-helmet"
import { ApiError, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { rateLimit, type Generator } from "elysia-rate-limit"
import { nanoid } from "nanoid/non-secure"

// Composed of various plugins to be used as a Service Locator
export const setup = new Elysia({ name: "setup" })
  // setup cors
  .use(
    cors({
      origin: ["https://inline.chat", "https://app.inline.chat", "http://localhost:8001"],
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
  .onError(({ code, error }) => {
    Log.shared.error("Top level error " + code, error)
    // TODO: Return something
  })
