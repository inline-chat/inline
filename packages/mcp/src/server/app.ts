import { notFound, text, withJson } from "./http/response"
import { OAuth } from "./oauth/routes"
import { Mcp } from "./mcp/handler"
import { createMemoryStore, type Store } from "./store"
import { defaultAllowedHosts, defaultAllowedOriginHosts, defaultConfig, type McpConfig } from "./config"

export type InlineMcpApp = {
  fetch(req: Request): Promise<Response>
}

export type CreateAppOptions = Partial<McpConfig> & {
  // Test seam.
  store?: Store
}

function normalizeHostLike(value: string): string | null {
  const trimmed = value.trim()
  if (!trimmed) return null
  try {
    const parsed = new URL(trimmed)
    if (parsed.hostname) return parsed.hostname.toLowerCase()
  } catch {
  }
  try {
    const parsed = new URL(`http://${trimmed}`)
    return parsed.hostname ? parsed.hostname.toLowerCase() : null
  } catch {
    return null
  }
}

function resolveClientIp(req: Request): string {
  const forwarded = req.headers.get("x-forwarded-for")
  if (forwarded) {
    const first = forwarded.split(",", 1)[0]?.trim()
    if (first) return first.toLowerCase()
  }

  const realIp = req.headers.get("x-real-ip")
  if (realIp?.trim()) return realIp.trim().toLowerCase()

  const cfConnectingIp = req.headers.get("cf-connecting-ip")
  if (cfConnectingIp?.trim()) return cfConnectingIp.trim().toLowerCase()

  return "unknown"
}

function isAllowedHost(req: Request, url: URL, config: McpConfig): boolean {
  const hostHeader = req.headers.get("host")
  const host = normalizeHostLike(hostHeader ?? url.host)
  if (!host) return false
  return config.allowedHosts.includes(host)
}

function isAllowedOrigin(req: Request, config: McpConfig): boolean {
  const origin = req.headers.get("origin")
  if (!origin) return true
  const originHost = normalizeHostLike(origin)
  if (!originHost) return false
  return config.allowedOriginHosts.includes(originHost)
}

export function createApp(options?: CreateAppOptions): InlineMcpApp {
  const defaulted = defaultConfig()
  const config = { ...defaulted, ...(options ?? {}) }
  if (options?.issuer && options.allowedHosts == null) {
    config.allowedHosts = defaultAllowedHosts(config.issuer)
  }
  if (options?.allowedOriginHosts == null && (options?.issuer != null || options?.allowedHosts != null)) {
    config.allowedOriginHosts = defaultAllowedOriginHosts(config.issuer, config.allowedHosts)
  }
  const store = options?.store ?? createMemoryStore()
  const mcp = Mcp.create({ config, store })

  return {
    async fetch(req) {
      const url = new URL(req.url)

      if (!isAllowedHost(req, url, config)) {
        return withJson({ error: "forbidden_host" }, { status: 403 })
      }
      if (!isAllowedOrigin(req, config)) {
        return withJson({ error: "forbidden_origin" }, { status: 403 })
      }
      if (url.pathname === "/mcp" && req.method === "POST" && !req.headers.get("mcp-session-id")) {
        const nowMs = Date.now()
        const ip = resolveClientIp(req)
        const rl = store.consumeRateLimit({
          key: `endpoint:mcp-init:${ip}`,
          nowMs,
          windowMs: config.endpointRateLimits.mcpInitialize.windowMs,
          max: config.endpointRateLimits.mcpInitialize.max,
        })
        if (!rl.allowed) {
          return withJson(
            { error: "rate_limited", error_description: "Too many MCP initialization attempts." },
            { status: 429, headers: { "retry-after": String(rl.retryAfterSeconds) } },
          )
        }
      }

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
