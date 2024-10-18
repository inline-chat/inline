import * as Sentry from "@sentry/bun"

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  tracesSampleRate: 1.0,
})

// Main app
// Entry point for your Elysia server, ideal place for setting global plugin
import { root } from "@in/server/controllers/root"
import { waitlist } from "@in/server/controllers/waitlist"
import { Elysia } from "elysia"
import { there } from "./controllers/there"
import { apiV001 } from "@in/server/controllers/v001"
import { setup } from "@in/server/setup"
import { Log } from "@in/server/utils/log"
import swagger from "@elysiajs/swagger"

const port = process.env.PORT || 8000

// Ensure to call this before importing any other modules!

const app = new Elysia()
  .use(root)
  .use(waitlist)
  .use(there)
  .use(apiV001)
  .use(
    swagger({
      path: "/v001/docs",
      exclude: /^(?!\/v001).*$/,
      scalarConfig: {
        servers: [
          {
            url: "https://api.inline.chat",
            description: "Production API server",
          },
        ],
      },
      documentation: {
        info: {
          title: "Inline API Docs",
          version: "0.0.1",
          contact: {
            email: "hi@inline.chat",
            name: "Inline Team",
            url: "https://inline.chat",
          },
          termsOfService: "https://inline.chat/terms",
        },
      },
    }),
  )
// .onError({ as: "local" }, ({ code, error }) => {
//   if (code === "NOT_FOUND") return "404"
//   console.error("error:", error)
//   Log.shared.error("Top level error " + code, error)
// })

// Run
app.listen(port, (server) => {
  console.info(
    `🚧 Server is running on http://${server.hostname}:${server.port}`,
  )
})
