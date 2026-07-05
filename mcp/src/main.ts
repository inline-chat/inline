import { createApp } from "./server/app"
import { defaultConfig } from "./server/config"

const port = Number(process.env.PORT ?? "8791")
const config = defaultConfig()
const app = createApp(config)

Bun.serve({
  port,
  fetch: app.fetch,
})

// Keep logs minimal and never include tokens.
console.log(`inline mcp listening on http://localhost:${port}`)
