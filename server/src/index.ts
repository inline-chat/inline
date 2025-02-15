import * as Sentry from "@sentry/bun"
import { SENTRY_DSN } from "@in/server/env"
import { gitCommitHash, version } from "@in/server/buildEnv"

Sentry.init({
  dsn: SENTRY_DSN,
  tracesSampleRate: 1.0,
  enabled: process.env.NODE_ENV !== "development",
})

// Main app
// Entry point for your Elysia server, ideal place for setting global plugin
import { root } from "@in/server/controllers/root"
import { waitlist } from "@in/server/controllers/extra/waitlist"
import { Elysia, t } from "elysia"
import { there } from "./controllers/extra/there"
import swagger from "@elysiajs/swagger"
import { apiV1 } from "@in/server/controllers/v1"
import { webSocket } from "@in/server/ws"
import { connectionManager } from "@in/server/ws/connections"
import { Log } from "@in/server/utils/log"
import { realtime } from "@in/server/realtime"

const port = process.env["PORT"] || 8000

// Ensure to call this before importing any other modules!

if (process.env.NODE_ENV !== "development") {
  Log.shared.info(`🚧 Starting server • ${process.env.NODE_ENV} • ${version} • ${gitCommitHash}`)
}

export const app = new Elysia()
  .use(root)
  .use(apiV1)
  .use(webSocket)
  .use(realtime)
  .use(waitlist)
  .use(there)
  .use(
    swagger({
      path: "/v1/docs",
      exclude: /^(?!\/v1).*$/,
      scalarConfig: {
        servers: [
          {
            url: process.env["NODE_ENV"] === "production" ? "https://api.inline.chat" : "http://localhost:8000",
            description: "Production API server",
          },
        ],
      },
      documentation: {
        info: {
          title: "Inline HTTP API Docs",
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

// Run
app.listen(port, (server) => {
  connectionManager.setServer(server)
  Log.shared.info(`✅ Server is running on http://${server.hostname}:${server.port}`)
})
