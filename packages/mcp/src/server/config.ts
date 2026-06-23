export type McpConfig = {
  issuer: string
  inlineApiBaseUrl: string
  oauthIssuer: string
  oauthProxyBaseUrl: string
  oauthIntrospectionUrl: string
  oauthInternalSharedSecret: string | null
  allowedHosts: string[]
  allowedOriginHosts: string[]
  endpointRateLimits: {
    mcpInitialize: RateLimitRule
  }
}

export type RateLimitRule = {
  max: number
  windowMs: number
}

const LOCAL_DEV_HOSTS = ["localhost", "127.0.0.1", "[::1]"]
const DEFAULT_ISSUER = "https://mcp.inline.chat"
const DEFAULT_INLINE_API_BASE_URL = "https://api.inline.chat"
const DEFAULT_OAUTH_ISSUER = "https://api.inline.chat"
const DEFAULT_OAUTH_PROXY_BASE_URL = "https://api.inline.chat"
const DEFAULT_OAUTH_INTROSPECTION_URL = "https://api.inline.chat/oauth/introspect"
const DEFAULT_PUBLIC_ORIGIN_HOSTS = ["chatgpt.com", "chat.openai.com", "claude.ai"]

function parsePositiveIntEnv(name: string, fallback: number, opts: { min: number; max: number }): number {
  const raw = process.env[name]
  if (!raw) return fallback
  const parsed = Number(raw)
  if (!Number.isFinite(parsed)) return fallback
  const value = Math.trunc(parsed)
  if (value < opts.min || value > opts.max) return fallback
  return value
}

function parseRateLimitRuleEnv(prefix: string, fallback: RateLimitRule): RateLimitRule {
  return {
    max: parsePositiveIntEnv(`${prefix}_MAX`, fallback.max, { min: 1, max: 100_000 }),
    windowMs: parsePositiveIntEnv(`${prefix}_WINDOW_MS`, fallback.windowMs, {
      min: 1_000,
      max: 24 * 60 * 60_000,
    }),
  }
}

function normalizeHostLike(value: string): string | null {
  const trimmed = value.trim()
  if (!trimmed) return null
  try {
    const parsed = new URL(trimmed)
    if (parsed.hostname) return parsed.hostname.toLowerCase()
  } catch {
  }
  // Accept hostnames with or without a port.
  try {
    const parsed = new URL(`http://${trimmed}`)
    return parsed.hostname ? parsed.hostname.toLowerCase() : null
  } catch {
    return null
  }
}

function uniqueNonEmpty(values: Array<string | null>): string[] {
  const out = new Set<string>()
  for (const value of values) {
    if (!value) continue
    out.add(value)
  }
  return [...out]
}

export function defaultAllowedHosts(issuer: string): string[] {
  const issuerHost = normalizeHostLike(issuer)
  if (!issuerHost) return [...LOCAL_DEV_HOSTS]
  if (LOCAL_DEV_HOSTS.includes(issuerHost)) {
    return uniqueNonEmpty([issuerHost, ...LOCAL_DEV_HOSTS])
  }
  return [issuerHost]
}

export function defaultAllowedOriginHosts(issuer: string, allowedHosts: string[]): string[] {
  const issuerHost = normalizeHostLike(issuer)
  if (issuerHost && LOCAL_DEV_HOSTS.includes(issuerHost)) return allowedHosts
  return uniqueNonEmpty([...allowedHosts, ...DEFAULT_PUBLIC_ORIGIN_HOSTS])
}

export function defaultConfig(): McpConfig {
  const baseAllowedHosts = defaultAllowedHosts(DEFAULT_ISSUER)
  return {
    issuer: DEFAULT_ISSUER,
    inlineApiBaseUrl: DEFAULT_INLINE_API_BASE_URL,
    oauthIssuer: DEFAULT_OAUTH_ISSUER,
    oauthProxyBaseUrl: DEFAULT_OAUTH_PROXY_BASE_URL,
    oauthIntrospectionUrl: DEFAULT_OAUTH_INTROSPECTION_URL,
    oauthInternalSharedSecret: process.env.MCP_INTERNAL_SHARED_SECRET || null,
    allowedHosts: baseAllowedHosts,
    allowedOriginHosts: defaultAllowedOriginHosts(DEFAULT_ISSUER, baseAllowedHosts),
    endpointRateLimits: {
      mcpInitialize: parseRateLimitRuleEnv("MCP_RATE_LIMIT_MCP_INIT", { max: 30, windowMs: 60_000 }),
    },
  }
}
