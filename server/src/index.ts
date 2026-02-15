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
import { health } from "@in/server/controllers/health"
import { startDatabaseHealthMonitor } from "@in/server/modules/monitoring/databaseHealthMonitor"
import { registerGracefulShutdown } from "@in/server/lifecycle/gracefulShutdown"
import { waitlist } from "@in/server/controllers/extra/waitlist"
import { Elysia } from "elysia"
import { there } from "./controllers/extra/there"
import swagger from "@elysiajs/swagger"
import { apiV1 } from "@in/server/controllers/v1"
import { botApi } from "@in/server/controllers/bot/bot"
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
  .use(health)
  .use(root)
  .use(apiV1)
  .use(botApi)
  .use(realtime)
  .use(waitlist)
  .use(there)
  .use(integrationsRouter)
  .use(admin)

  .use(
    swagger({
      path: "/v1/reference",
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

  .use(
    swagger({
      // Keep the docs route out of the `/bot/*` namespace so it doesn't look like a bot method.
      path: "/bot-api-reference",
      exclude: /^(?!\/bot).*$/,
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
          title: "Inline Bot HTTP API Docs",
          version: "0.0.1",
          description: [
            "## Authentication",
            "",
            "Recommended: send the bot token via the `Authorization: Bearer <token>` header.",
            "",
            "Alternative: include the token in the URL path using `/bot<token>/<method>`.",
            "",
            "For method parameters, use JSON request body (recommended). Query parameters on POST are also accepted for compatibility.",
            "",
            "Tokens look like `123:IN...` and contain a `:`. Most HTTP clients handle this in the path fine, but if yours doesn't, URL-encode the token segment (e.g. `:` -> `%3A`).",
            "",
            "### Header auth (recommended)",
            "",
            "```bash",
            "curl -sS \\",
            "  -H 'Authorization: Bearer <token>' \\",
            "  -H 'Content-Type: application/json' \\",
            "  -X POST 'https://api.inline.chat/bot/sendMessage' \\",
            "  -d '{\"user_id\": 1001, \"text\": \"hello from bot\"}'",
            "```",
            "",
            "### Token in path",
            "",
            "```bash",
            "curl -sS \\",
            "  -H 'Content-Type: application/json' \\",
            "  -X POST 'https://api.inline.chat/bot<token>/sendMessage' \\",
            "  -d '{\"chat_id\": 42, \"text\": \"hello from bot\"}'",
            "```",
            "",
            "Targeting: use `chat_id` (canonical) or `user_id` for DMs. Deprecated aliases `peer_thread_id` and `peer_user_id` are still accepted for compatibility.",
            "",
            "### Quick check",
            "",
            "```bash",
            "curl -sS 'https://api.inline.chat/bot<token>/getMe'",
            "```",
          ].join("\n"),
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
  startDatabaseHealthMonitor()
  registerGracefulShutdown(server)
  log.info(`Running on http://${server.hostname}:${server.port}`)
})
