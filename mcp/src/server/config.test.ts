import { afterEach, describe, expect, it } from "vitest"
import { defaultConfig } from "./config"

const ENV_KEYS = [
  "MCP_ISSUER",
  "INLINE_API_BASE_URL",
  "MCP_OAUTH_ISSUER",
  "MCP_OAUTH_PROXY_BASE_URL",
  "MCP_OAUTH_INTROSPECTION_URL",
  "MCP_ALLOWED_HOSTS",
  "MCP_ALLOWED_ORIGINS",
  "MCP_INTERNAL_SHARED_SECRET",
  "MCP_RATE_LIMIT_MCP_INIT_MAX",
  "MCP_RATE_LIMIT_MCP_INIT_WINDOW_MS",
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
    expect(config.inlineApiBaseUrl).toBe("https://api.inline.chat")
    expect(config.oauthIssuer).toBe("https://api.inline.chat")
    expect(config.oauthProxyBaseUrl).toBe("https://api.inline.chat")
    expect(config.oauthIntrospectionUrl).toBe("https://api.inline.chat/oauth/introspect")
    expect(config.allowedHosts).toEqual(["mcp.inline.chat"])
    expect(config.allowedOriginHosts).toEqual(["mcp.inline.chat", "chatgpt.com", "chat.openai.com", "claude.ai"])
    expect(config.endpointRateLimits.mcpInitialize.max).toBe(30)
  })

  it("uses fixed production endpoints and allowlists", () => {
    clearManagedEnv()
    ;(process.env as Record<string, string>)["MCP_ISSUER"] = "http://localhost:8791"
    ;(process.env as Record<string, string>)["INLINE_API_BASE_URL"] = "https://example.com"
    ;(process.env as Record<string, string>)["MCP_OAUTH_ISSUER"] = "https://oauth.example.com"
    ;(process.env as Record<string, string>)["MCP_OAUTH_PROXY_BASE_URL"] = "https://proxy.example.com"
    ;(process.env as Record<string, string>)["MCP_OAUTH_INTROSPECTION_URL"] = "https://proxy.example.com/introspect"
    ;(process.env as Record<string, string>)["MCP_ALLOWED_HOSTS"] = "localhost"
    ;(process.env as Record<string, string>)["MCP_ALLOWED_ORIGINS"] = "localhost"

    const config = defaultConfig()
    expect(config.issuer).toBe("https://mcp.inline.chat")
    expect(config.inlineApiBaseUrl).toBe("https://api.inline.chat")
    expect(config.oauthIssuer).toBe("https://api.inline.chat")
    expect(config.oauthProxyBaseUrl).toBe("https://api.inline.chat")
    expect(config.oauthIntrospectionUrl).toBe("https://api.inline.chat/oauth/introspect")
    expect(config.allowedHosts).toEqual(["mcp.inline.chat"])
    expect(config.allowedOriginHosts).toEqual(["mcp.inline.chat", "chatgpt.com", "chat.openai.com", "claude.ai"])
  })

  it("reads shared secret from env", () => {
    clearManagedEnv()
    process.env.MCP_INTERNAL_SHARED_SECRET = "super-secret"

    const config = defaultConfig()
    expect(config.oauthInternalSharedSecret).toBe("super-secret")
  })

  it("parses configured mcp init rate limits from env", () => {
    clearManagedEnv()
    process.env.MCP_RATE_LIMIT_MCP_INIT_MAX = "15.9"
    process.env.MCP_RATE_LIMIT_MCP_INIT_WINDOW_MS = "45000"

    const config = defaultConfig()
    expect(config.endpointRateLimits.mcpInitialize.max).toBe(15)
    expect(config.endpointRateLimits.mcpInitialize.windowMs).toBe(45000)
  })

  it("ignores invalid/out-of-range rate limit env values", () => {
    clearManagedEnv()
    process.env.MCP_RATE_LIMIT_MCP_INIT_MAX = "0"
    process.env.MCP_RATE_LIMIT_MCP_INIT_WINDOW_MS = "10"

    const config = defaultConfig()
    expect(config.endpointRateLimits.mcpInitialize.max).toBe(30)
    expect(config.endpointRateLimits.mcpInitialize.windowMs).toBe(60_000)
  })

  it("defaults secret to null", () => {
    clearManagedEnv()
    const config = defaultConfig()
    expect(config.oauthInternalSharedSecret).toBeNull()
  })
})
