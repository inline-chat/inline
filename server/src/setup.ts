import Elysia from "elysia"
import cors from "@elysiajs/cors"
import { helmet } from "elysia-helmet"
import { rateLimit } from "elysia-rate-limit"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"

// Composed of various plugins to be used as a Service Locator
export const setup = new Elysia({ name: "setup" })
  // setup cors
  .use(
    cors({
      origin: [
        "https://inline.chat",
        "https://app.inline.chat",
        "http://localhost:8001",
      ],
    }),
  )
  .use(helmet())
  .error("INLINE_ERROR", InlineError)
  .onError(({ code, error }) => {
    Log.shared.error("Top level error " + code, error)
  })
