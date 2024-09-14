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

const port = process.env.PORT || 8000

// Ensure to call this before importing any other modules!

const app = new Elysia()
  .use(root)
  .use(waitlist)
  .onError(({ code, error }) => {
    if (code === "NOT_FOUND") return "404"
    console.error("error:", error)
    Sentry.captureException(error)
  })

// Run
app.listen(port, (server) => {
  console.info(
    `🚧 Server is running on http://${server.hostname}:${server.port}`,
  )
})
