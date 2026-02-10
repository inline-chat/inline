import { notFound, text, withJson } from "./http/response"
import { OAuth } from "./oauth/routes"
import { Mcp } from "./mcp/handler"
import { createMemoryStore, type Store } from "./store"
import { defaultConfig, type McpConfig } from "./config"

export type InlineMcpApp = {
  fetch(req: Request): Promise<Response>
}

export type CreateAppOptions = Partial<McpConfig> & {
  // Test seam.
  store?: Store
}

export function createApp(options?: CreateAppOptions): InlineMcpApp {
  const config = { ...defaultConfig(), ...(options ?? {}) }
  const store = options?.store ?? createMemoryStore()
  const mcp = Mcp.create({ config, store })

  return {
    async fetch(req) {
      const url = new URL(req.url)

      if (url.pathname === "/health") {
        return withJson({ ok: true })
      }

      const mcpRes = await mcp.handle(req, url)
      if (mcpRes) return mcpRes

      const oauthRes = await OAuth.handle(req, url, config, store)
      if (oauthRes) return oauthRes

      if (url.pathname === "/") {
        return text(200, "Inline MCP server (see /health)")
      }

      return notFound()
    },
  }
}
