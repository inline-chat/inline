export type McpConfig = {
  issuer: string
  inlineApiBaseUrl: string
  dbPath: string
  tokenEncryptionKeyB64: string | null
  // Used for generating a stable cookie name to avoid collisions across envs.
  cookiePrefix: string
  allowedHosts: string[]
  allowedOriginHosts: string[]
  endpointRateLimits: {
    sendEmailCode: RateLimitRule
    verifyEmailCode: RateLimitRule
    token: RateLimitRule
    mcpInitialize: RateLimitRule
  }
  emailAbuseRateLimits: {
    sendPerEmail: RateLimitRule
    sendPerContext: RateLimitRule
    verifyPerEmail: RateLimitRule
    verifyPerContext: RateLimitRule
  }
}

export type RateLimitRule = {
  max: number
  windowMs: number
}

const LOCAL_DEV_HOSTS = ["localhost", "127.0.0.1", "[::1]"]
const DEFAULT_ISSUER = "https://mcp.inline.chat"
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

function parseCsv(raw: string | undefined): string[] {
  if (!raw) return []
  return raw
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean)
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

function parseHostAllowlist(raw: string | undefined, fallback: string[]): string[] {
  const parsed = parseCsv(raw).map(normalizeHostLike)
  const normalized = uniqueNonEmpty(parsed)
  return normalized.length > 0 ? normalized : fallback
}

export function defaultConfig(): McpConfig {
  const issuer = process.env.MCP_ISSUER || DEFAULT_ISSUER
  const allowedHosts = parseHostAllowlist(process.env.MCP_ALLOWED_HOSTS, defaultAllowedHosts(issuer))
  const allowedOriginHosts = parseHostAllowlist(
    process.env.MCP_ALLOWED_ORIGINS,
    defaultAllowedOriginHosts(issuer, allowedHosts),
  )

  return {
    issuer,
    inlineApiBaseUrl: process.env.INLINE_API_BASE_URL || "https://api.inline.chat",
    dbPath: process.env.MCP_DB_PATH || "./data/inline-mcp.sqlite",
    tokenEncryptionKeyB64: process.env.MCP_TOKEN_ENCRYPTION_KEY_B64 || null,
    cookiePrefix: process.env.MCP_COOKIE_PREFIX || "inline_mcp",
    allowedHosts,
    allowedOriginHosts,
    endpointRateLimits: {
      sendEmailCode: parseRateLimitRuleEnv("MCP_RATE_LIMIT_SEND_EMAIL_CODE", { max: 10, windowMs: 10 * 60_000 }),
      verifyEmailCode: parseRateLimitRuleEnv("MCP_RATE_LIMIT_VERIFY_EMAIL_CODE", { max: 20, windowMs: 10 * 60_000 }),
      token: parseRateLimitRuleEnv("MCP_RATE_LIMIT_TOKEN", { max: 60, windowMs: 60_000 }),
      mcpInitialize: parseRateLimitRuleEnv("MCP_RATE_LIMIT_MCP_INIT", { max: 30, windowMs: 60_000 }),
    },
    emailAbuseRateLimits: {
      sendPerEmail: parseRateLimitRuleEnv("MCP_EMAIL_ABUSE_SEND_PER_EMAIL", { max: 4, windowMs: 10 * 60_000 }),
      sendPerContext: parseRateLimitRuleEnv("MCP_EMAIL_ABUSE_SEND_PER_CONTEXT", { max: 6, windowMs: 10 * 60_000 }),
      verifyPerEmail: parseRateLimitRuleEnv("MCP_EMAIL_ABUSE_VERIFY_PER_EMAIL", { max: 10, windowMs: 10 * 60_000 }),
      verifyPerContext: parseRateLimitRuleEnv("MCP_EMAIL_ABUSE_VERIFY_PER_CONTEXT", { max: 12, windowMs: 10 * 60_000 }),
    },
  }
}
