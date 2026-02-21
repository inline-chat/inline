import { notFound, text, withJson } from "./http/response"
import { OAuth } from "./oauth/routes"
import { Mcp } from "./mcp/handler"
import { defaultAllowedHosts, defaultAllowedOriginHosts, defaultConfig, type McpConfig } from "./config"

export type InlineMcpApp = {
  fetch(req: Request): Promise<Response>
}

export type CreateAppOptions = Partial<McpConfig>

type RateLimitBucket = {
  count: number
  resetAtMs: number
}

const CORS_ALLOWED_METHODS = "GET, POST, DELETE, OPTIONS"
const CORS_ALLOWED_HEADERS = "authorization, content-type, accept, mcp-session-id"
const CORS_EXPOSE_HEADERS = "mcp-session-id, www-authenticate"
const CORS_MAX_AGE_SECONDS = "600"

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

function addVary(headers: Headers, value: string): void {
  const existing = headers.get("vary")
  if (!existing) {
    headers.set("vary", value)
    return
  }

  const normalized = value.toLowerCase()
  const existingValues = existing
    .split(",")
    .map((part) => part.trim().toLowerCase())
    .filter(Boolean)
  if (existingValues.includes(normalized)) return
  headers.set("vary", `${existing}, ${value}`)
}

function preflight(req: Request, origin: string): Response {
  const requestHeaders = req.headers.get("access-control-request-headers")
  const allowHeaders = requestHeaders && requestHeaders.trim().length > 0 ? requestHeaders : CORS_ALLOWED_HEADERS
  const headers = new Headers({
    "access-control-allow-origin": origin,
    "access-control-allow-methods": CORS_ALLOWED_METHODS,
    "access-control-allow-headers": allowHeaders,
    "access-control-max-age": CORS_MAX_AGE_SECONDS,
  })
  addVary(headers, "origin")
  addVary(headers, "access-control-request-method")
  addVary(headers, "access-control-request-headers")
  return new Response(null, { status: 204, headers })
}

function withCors(res: Response, origin: string): Response {
  const headers = new Headers(res.headers)
  headers.set("access-control-allow-origin", origin)
  headers.set("access-control-expose-headers", CORS_EXPOSE_HEADERS)
  addVary(headers, "origin")
  return new Response(res.body, {
    status: res.status,
    statusText: res.statusText,
    headers,
  })
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

  const mcp = Mcp.create({ config })
  const initRateLimits = new Map<string, RateLimitBucket>()

  const consumeInitRateLimit = (key: string, nowMs: number): { allowed: boolean; retryAfterSeconds: number } => {
    const bucket = initRateLimits.get(key)
    const rule = config.endpointRateLimits.mcpInitialize

    if (!bucket || bucket.resetAtMs <= nowMs) {
      initRateLimits.set(key, { count: 1, resetAtMs: nowMs + rule.windowMs })
      return { allowed: true, retryAfterSeconds: 0 }
    }

    bucket.count += 1
    const allowed = bucket.count <= rule.max
    const retryAfterSeconds = allowed ? 0 : Math.max(1, Math.ceil((bucket.resetAtMs - nowMs) / 1000))
    return { allowed, retryAfterSeconds }
  }

  return {
    async fetch(req) {
      const url = new URL(req.url)

      if (!isAllowedHost(req, url, config)) {
        return withJson({ error: "forbidden_host" }, { status: 403 })
      }

      const origin = req.headers.get("origin")

      if (!isAllowedOrigin(req, config)) {
        return withJson({ error: "forbidden_origin" }, { status: 403 })
      }

      if (req.method === "OPTIONS" && origin && req.headers.get("access-control-request-method")) {
        return preflight(req, origin)
      }

      const finish = (res: Response): Response => {
        if (!origin) return res
        return withCors(res, origin)
      }

      if (url.pathname === "/mcp" && req.method === "POST" && !req.headers.get("mcp-session-id")) {
        const nowMs = Date.now()
        const ip = resolveClientIp(req)
        const rateLimit = consumeInitRateLimit(`endpoint:mcp-init:${ip}`, nowMs)

        if (!rateLimit.allowed) {
          return finish(
            withJson(
              { error: "rate_limited", error_description: "Too many MCP initialization attempts." },
              {
                status: 429,
                headers: { "retry-after": String(rateLimit.retryAfterSeconds) },
              },
            ),
          )
        }
      }

      if (url.pathname === "/health") {
        return finish(withJson({ ok: true }))
      }

      const mcpRes = await mcp.handle(req, url)
      if (mcpRes) return finish(mcpRes)

      const oauthRes = await OAuth.handle(req, url, config)
      if (oauthRes) return finish(oauthRes)

      if (url.pathname === "/") {
        return finish(text(200, "Inline MCP server (see /health)"))
      }

      return finish(notFound())
    },
  }
}
