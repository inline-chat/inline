import { describe, expect, it } from "bun:test"
import {
  MCP_DEFAULT_SCOPE,
  base64UrlDecode,
  base64UrlEncode,
  constantTimeEqual,
  createRandomToken,
  hasScope,
  isAllowedRedirectUri,
  normalizeEmail,
  normalizeRateLimitKeyPart,
  normalizeScopes,
  sha256Base64Url,
  sha256Hex,
} from "./index"

describe("oauth-core", () => {
  it("normalizes and filters scopes", () => {
    expect(normalizeScopes("messages:read messages:read unknown spaces:read")).toBe("messages:read spaces:read")
    expect(normalizeScopes("")).toBe(MCP_DEFAULT_SCOPE)
  })

  it("checks scope membership", () => {
    expect(hasScope("messages:read spaces:read", "messages:read")).toBe(true)
    expect(hasScope("messages:read spaces:read", "messages:write")).toBe(false)
  })

  it("normalizes email and key parts", () => {
    expect(normalizeEmail("  Test@Example.COM  ")).toBe("test@example.com")
    expect(normalizeRateLimitKeyPart("  USER@EXAMPLE.COM  ")).toBe("user@example.com")
    expect(normalizeRateLimitKeyPart("   ")).toBe("unknown")
  })

  it("validates redirect uri rules", () => {
    expect(isAllowedRedirectUri("https://example.com/callback")).toBe(true)
    expect(isAllowedRedirectUri("http://localhost:3000/callback")).toBe(true)
    expect(isAllowedRedirectUri("http://evil.example/callback")).toBe(false)
    expect(isAllowedRedirectUri("inline://callback")).toBe(false)
  })

  it("encodes and decodes base64url", () => {
    const original = new Uint8Array([1, 2, 3, 254, 255])
    const encoded = base64UrlEncode(original)
    expect(base64UrlDecode(encoded)).toEqual(original)
  })

  it("hashes strings", async () => {
    expect(await sha256Hex("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    expect(await sha256Base64Url("abc")).toBe("ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0")
  })

  it("compares in constant time for equal-length strings", () => {
    expect(constantTimeEqual("abc", "abc")).toBe(true)
    expect(constantTimeEqual("abc", "abd")).toBe(false)
    expect(constantTimeEqual("abc", "ab")).toBe(false)
  })

  it("creates random prefixed tokens", () => {
    const tokenA = createRandomToken("mcp_at")
    const tokenB = createRandomToken("mcp_at")
    expect(tokenA.startsWith("mcp_at_")).toBe(true)
    expect(tokenB.startsWith("mcp_at_")).toBe(true)
    expect(tokenA).not.toBe(tokenB)
  })
})
