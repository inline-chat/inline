import { afterEach, describe, expect, it } from "bun:test"
import { oauthConfig } from "./config"

const savedAccessTtl = process.env["MCP_OAUTH_ACCESS_TOKEN_TTL_MS"]
const savedRefreshTtl = process.env["MCP_OAUTH_REFRESH_TOKEN_TTL_MS"]
const savedResource = process.env["MCP_OAUTH_RESOURCE"]

afterEach(() => {
  restoreEnv("MCP_OAUTH_ACCESS_TOKEN_TTL_MS", savedAccessTtl)
  restoreEnv("MCP_OAUTH_REFRESH_TOKEN_TTL_MS", savedRefreshTtl)
  restoreEnv("MCP_OAUTH_RESOURCE", savedResource)
})

describe("oauthConfig", () => {
  it("defaults to durable MCP session lifetimes", () => {
    delete process.env["MCP_OAUTH_ACCESS_TOKEN_TTL_MS"]
    delete process.env["MCP_OAUTH_REFRESH_TOKEN_TTL_MS"]
    delete process.env["MCP_OAUTH_RESOURCE"]

    const config = oauthConfig()

    expect(config.accessTokenTtlMs).toBe(2 * 60 * 60_000)
    expect(config.refreshTokenTtlMs).toBe(180 * 24 * 60 * 60_000)
    expect(config.resource).toBe("https://mcp.inline.chat")
  })

  it("allows bounded lifetime and resource overrides", () => {
    process.env["MCP_OAUTH_ACCESS_TOKEN_TTL_MS"] = String(3 * 60 * 60_000)
    process.env["MCP_OAUTH_REFRESH_TOKEN_TTL_MS"] = String(200 * 24 * 60 * 60_000)
    process.env["MCP_OAUTH_RESOURCE"] = "https://mcp.example.com"

    const config = oauthConfig()

    expect(config.accessTokenTtlMs).toBe(3 * 60 * 60_000)
    expect(config.refreshTokenTtlMs).toBe(200 * 24 * 60 * 60_000)
    expect(config.resource).toBe("https://mcp.example.com")
  })
})

function restoreEnv(name: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[name]
  } else {
    process.env[name] = value
  }
}
