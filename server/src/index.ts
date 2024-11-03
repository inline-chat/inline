import * as Sentry from "@sentry/bun"
import { SENTRY_DSN } from "@in/server/env"
import { gitCommitHash, version } from "@in/server/buildEnv"

Sentry.init({
  dsn: SENTRY_DSN,
  tracesSampleRate: 1.0,
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

const port = process.env["PORT"] || 8000

// Ensure to call this before importing any other modules!

console.log(`🚧 Starting server... (${process.env.NODE_ENV}, ${version}, ${gitCommitHash})`)

const app = new Elysia()
  .use(root)
  .use(apiV1)
  .use(webSocket)
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
  console.info(`✅ Server is running on http://${server.hostname}:${server.port}`)
})
