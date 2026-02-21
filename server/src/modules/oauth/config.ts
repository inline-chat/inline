import { API_BASE_URL } from "@in/server/env"
import type { RateLimitRule } from "@in/server/modules/oauth/rateLimiter"

export type OauthServerConfig = {
  issuer: string
  cookiePrefix: string
  authRequestTtlMs: number
  authCodeTtlMs: number
  accessTokenTtlMs: number
  refreshTokenTtlMs: number
  endpointRateLimits: {
    register: RateLimitRule
    sendEmailCode: RateLimitRule
    verifyEmailCode: RateLimitRule
    token: RateLimitRule
  }
  emailAbuseRateLimits: {
    sendPerEmail: RateLimitRule
    sendPerContext: RateLimitRule
    verifyPerEmail: RateLimitRule
    verifyPerContext: RateLimitRule
  }
  internalSharedSecret: string | null
}

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

export function oauthConfig(): OauthServerConfig {
  const issuer = process.env["MCP_OAUTH_ISSUER"] || API_BASE_URL

  return {
    issuer,
    cookiePrefix: process.env["MCP_OAUTH_COOKIE_PREFIX"] || "inline_mcp",
    authRequestTtlMs: parsePositiveIntEnv("MCP_OAUTH_AUTH_REQUEST_TTL_MS", 15 * 60_000, {
      min: 60_000,
      max: 24 * 60 * 60_000,
    }),
    authCodeTtlMs: parsePositiveIntEnv("MCP_OAUTH_AUTH_CODE_TTL_MS", 5 * 60_000, {
      min: 30_000,
      max: 2 * 60 * 60_000,
    }),
    accessTokenTtlMs: parsePositiveIntEnv("MCP_OAUTH_ACCESS_TOKEN_TTL_MS", 60 * 60_000, {
      min: 60_000,
      max: 7 * 24 * 60 * 60_000,
    }),
    refreshTokenTtlMs: parsePositiveIntEnv("MCP_OAUTH_REFRESH_TOKEN_TTL_MS", 30 * 24 * 60 * 60_000, {
      min: 60_000,
      max: 365 * 24 * 60 * 60_000,
    }),
    endpointRateLimits: {
      register: parseRateLimitRuleEnv("MCP_OAUTH_RATE_LIMIT_REGISTER", { max: 30, windowMs: 60_000 }),
      sendEmailCode: parseRateLimitRuleEnv("MCP_OAUTH_RATE_LIMIT_SEND_EMAIL_CODE", { max: 10, windowMs: 10 * 60_000 }),
      verifyEmailCode: parseRateLimitRuleEnv("MCP_OAUTH_RATE_LIMIT_VERIFY_EMAIL_CODE", { max: 20, windowMs: 10 * 60_000 }),
      token: parseRateLimitRuleEnv("MCP_OAUTH_RATE_LIMIT_TOKEN", { max: 60, windowMs: 60_000 }),
    },
    emailAbuseRateLimits: {
      sendPerEmail: parseRateLimitRuleEnv("MCP_OAUTH_EMAIL_ABUSE_SEND_PER_EMAIL", { max: 4, windowMs: 10 * 60_000 }),
      sendPerContext: parseRateLimitRuleEnv("MCP_OAUTH_EMAIL_ABUSE_SEND_PER_CONTEXT", { max: 6, windowMs: 10 * 60_000 }),
      verifyPerEmail: parseRateLimitRuleEnv("MCP_OAUTH_EMAIL_ABUSE_VERIFY_PER_EMAIL", { max: 10, windowMs: 10 * 60_000 }),
      verifyPerContext: parseRateLimitRuleEnv("MCP_OAUTH_EMAIL_ABUSE_VERIFY_PER_CONTEXT", { max: 12, windowMs: 10 * 60_000 }),
    },
    internalSharedSecret: process.env["MCP_INTERNAL_SHARED_SECRET"] || null,
  }
}
