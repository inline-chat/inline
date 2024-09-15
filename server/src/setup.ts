import Elysia from "elysia"
import cors from "@elysiajs/cors"
import { helmet } from "elysia-helmet"
import { rateLimit } from "elysia-rate-limit"

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
