import { createApp } from "./server/app"
import { createBunSqliteStore } from "./server/store/bun-sqlite-store"
import { defaultConfig } from "./server/config"

const port = Number(process.env.PORT ?? "8791")
const config = defaultConfig()
const store = createBunSqliteStore({ dbPath: config.dbPath })
const app = createApp({ ...config, store })

Bun.serve({
  port,
  fetch: app.fetch,
})

// Keep logs minimal and never include tokens.
console.log(`inline mcp listening on http://localhost:${port}`)
