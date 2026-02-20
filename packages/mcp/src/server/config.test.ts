import { afterEach, describe, expect, it } from "vitest"
import { defaultConfig } from "./config"

const ENV_KEYS = [
  "MCP_ISSUER",
  "MCP_ALLOWED_HOSTS",
  "MCP_ALLOWED_ORIGINS",
  "MCP_RATE_LIMIT_SEND_EMAIL_CODE_MAX",
  "MCP_RATE_LIMIT_SEND_EMAIL_CODE_WINDOW_MS",
  "MCP_RATE_LIMIT_VERIFY_EMAIL_CODE_MAX",
  "MCP_RATE_LIMIT_VERIFY_EMAIL_CODE_WINDOW_MS",
  "MCP_RATE_LIMIT_TOKEN_MAX",
  "MCP_RATE_LIMIT_TOKEN_WINDOW_MS",
  "MCP_RATE_LIMIT_MCP_INIT_MAX",
  "MCP_RATE_LIMIT_MCP_INIT_WINDOW_MS",
  "MCP_EMAIL_ABUSE_SEND_PER_EMAIL_MAX",
  "MCP_EMAIL_ABUSE_SEND_PER_EMAIL_WINDOW_MS",
  "MCP_EMAIL_ABUSE_SEND_PER_CONTEXT_MAX",
  "MCP_EMAIL_ABUSE_SEND_PER_CONTEXT_WINDOW_MS",
  "MCP_EMAIL_ABUSE_VERIFY_PER_EMAIL_MAX",
  "MCP_EMAIL_ABUSE_VERIFY_PER_EMAIL_WINDOW_MS",
  "MCP_EMAIL_ABUSE_VERIFY_PER_CONTEXT_MAX",
  "MCP_EMAIL_ABUSE_VERIFY_PER_CONTEXT_WINDOW_MS",
] as const

const ORIGINAL_ENV = new Map<string, string | undefined>(ENV_KEYS.map((key) => [key, process.env[key]]))

function clearManagedEnv() {
  for (const key of ENV_KEYS) {
    delete process.env[key]
  }
}

afterEach(() => {
  clearManagedEnv()
  for (const [key, value] of ORIGINAL_ENV.entries()) {
    if (value == null) {
      delete process.env[key]
    } else {
      process.env[key] = value
    }
  }
})

describe("defaultConfig", () => {
  it("provides production defaults", () => {
    clearManagedEnv()
    const config = defaultConfig()
    expect(config.issuer).toBe("https://mcp.inline.chat")
    expect(config.allowedHosts).toEqual(["mcp.inline.chat"])
    expect(config.allowedOriginHosts).toEqual(["mcp.inline.chat", "chatgpt.com", "chat.openai.com", "claude.ai"])
    expect(config.endpointRateLimits.mcpInitialize.max).toBe(30)
    expect(config.emailAbuseRateLimits.sendPerEmail.max).toBe(4)
  })

  it("derives issuer host and parses allowlists", () => {
    clearManagedEnv()
    process.env.MCP_ISSUER = "https://mcp.inline.chat"
    process.env.MCP_ALLOWED_HOSTS = "https://mcp.inline.chat, api.inline.chat:443, ,invalid host"
    process.env.MCP_ALLOWED_ORIGINS = "https://chat.openai.com, claude.ai"

    const config = defaultConfig()
    expect(config.allowedHosts).toEqual(["mcp.inline.chat", "api.inline.chat"])
    expect(config.allowedOriginHosts).toEqual(["chat.openai.com", "claude.ai"])
  })

  it("falls back to defaults when allowlist env values are invalid", () => {
    clearManagedEnv()
    process.env.MCP_ISSUER = "https://mcp.inline.chat"
    process.env.MCP_ALLOWED_HOSTS = " , :// , ???"
    delete process.env.MCP_ALLOWED_ORIGINS

    const config = defaultConfig()
    expect(config.allowedHosts).toEqual(["mcp.inline.chat"])
    expect(config.allowedOriginHosts).toEqual(["mcp.inline.chat", "chatgpt.com", "chat.openai.com", "claude.ai"])
  })

  it("parses configured rate limits from env", () => {
    clearManagedEnv()
    process.env.MCP_RATE_LIMIT_TOKEN_MAX = "15.9"
    process.env.MCP_RATE_LIMIT_TOKEN_WINDOW_MS = "45000"
    process.env.MCP_EMAIL_ABUSE_VERIFY_PER_CONTEXT_MAX = "8"
    process.env.MCP_EMAIL_ABUSE_VERIFY_PER_CONTEXT_WINDOW_MS = "120000"

    const config = defaultConfig()
    expect(config.endpointRateLimits.token.max).toBe(15)
    expect(config.endpointRateLimits.token.windowMs).toBe(45000)
    expect(config.emailAbuseRateLimits.verifyPerContext.max).toBe(8)
    expect(config.emailAbuseRateLimits.verifyPerContext.windowMs).toBe(120000)
  })

  it("ignores invalid/out-of-range rate limit env values", () => {
    clearManagedEnv()
    process.env.MCP_RATE_LIMIT_TOKEN_MAX = "0"
    process.env.MCP_RATE_LIMIT_TOKEN_WINDOW_MS = "10"
    process.env.MCP_EMAIL_ABUSE_SEND_PER_EMAIL_MAX = "not-a-number"
    process.env.MCP_EMAIL_ABUSE_SEND_PER_EMAIL_WINDOW_MS = "99999999999"

    const config = defaultConfig()
    expect(config.endpointRateLimits.token.max).toBe(60)
    expect(config.endpointRateLimits.token.windowMs).toBe(60000)
    expect(config.emailAbuseRateLimits.sendPerEmail.max).toBe(4)
    expect(config.emailAbuseRateLimits.sendPerEmail.windowMs).toBe(10 * 60_000)
  })
})
