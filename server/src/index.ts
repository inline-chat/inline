import * as Sentry from "@sentry/bun"
import { API_BASE_URL, NODE_ENV, PORT, SENTRY_DSN } from "@in/server/env"
import { gitCommitHash, version } from "@in/server/buildEnv"

Sentry.init({
  dsn: SENTRY_DSN,
  tracesSampleRate: 1.0,
  enabled: NODE_ENV !== "development",
  enableLogs: true,
})

// Main app
// Entry point for your Elysia server, ideal place for setting global plugin
import { root } from "@in/server/controllers/root"
import { waitlist } from "@in/server/controllers/extra/waitlist"
import { Elysia, t } from "elysia"
import { there } from "./controllers/extra/there"
import swagger from "@elysiajs/swagger"
import { apiV1 } from "@in/server/controllers/v1"
import { connectionManager } from "@in/server/ws/connections"
import { Log, LogLevel } from "@in/server/utils/log"
import { realtime } from "@in/server/realtime"
import { integrationsRouter } from "./controllers/integrations/integrationsRouter"
import { admin } from "./controllers/admin"
import type { Server } from "bun"
import { EventEmitter } from "events"

const port = PORT
const log = new Log("server", LogLevel.INFO)

// To fix a bug where 11 max listeners trigger a warning in production console
EventEmitter.defaultMaxListeners = 20

if (NODE_ENV === "production") {
  process.on("warning", (warning) => {
    if (
      warning?.name === "MaxListenersExceededWarning" &&
      warning.message.includes("wakeup listeners added to [Connection2]")
    ) {
      return
    }
    console.warn(warning)
  })
}

if (NODE_ENV !== "development") {
  Log.shared.info(`🚧 Starting server • ${NODE_ENV} • ${version} • ${gitCommitHash}`)
}

export const app = new Elysia()
  .use(root)
  .use(apiV1)
  .use(realtime)
  .use(waitlist)
  .use(there)
  .use(integrationsRouter)
  .use(admin)

  .use(
    swagger({
      path: "/v1/docs",
      exclude: /^(?!\/v1).*$/,
      scalarConfig: {
        servers: [
          {
            url: API_BASE_URL,
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
app.listen(port, (server: Server<unknown>) => {
  connectionManager.setServer(server)
  log.info(`Running on http://${server.hostname}:${server.port}`)
})
