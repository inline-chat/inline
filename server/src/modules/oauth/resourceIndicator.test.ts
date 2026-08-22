import { describe, expect, it } from "bun:test"
import { normalizeMcpResourceIndicator } from "./resourceIndicator"

const canonical = "https://mcp.inline.chat"

describe("normalizeMcpResourceIndicator", () => {
  it("normalizes the canonical audience and hosted transport endpoints", () => {
    for (const resource of [
      undefined,
      canonical,
      `${canonical}/`,
      `${canonical}/mcp`,
      `${canonical}/mcp/`,
      `${canonical}/mcp/v2`,
      `${canonical}/mcp/v2/`,
    ]) {
      expect(normalizeMcpResourceIndicator(resource, canonical)).toBe(canonical)
    }
  })

  it("rejects audiences outside the explicit MCP endpoint aliases", () => {
    for (const resource of [
      "https://mcp.inline.chat/other",
      "https://mcp.inline.chat/mcp/v3",
      "https://mcp.inline.chat/mcp/v2?tenant=other",
      "https://mcp.inline.chat/mcp/v2#fragment",
      "https://user@mcp.inline.chat/mcp/v2",
      "https://other.example/mcp/v2",
      "not-a-url",
    ]) {
      expect(normalizeMcpResourceIndicator(resource, canonical)).toBeNull()
    }
  })

  it("does not add MCP path aliases to a path-scoped custom audience", () => {
    const customCanonical = "https://mcp.example.test/protected"
    expect(normalizeMcpResourceIndicator(`${customCanonical}/`, customCanonical)).toBe(customCanonical)
    expect(normalizeMcpResourceIndicator("https://mcp.example.test/mcp/v2", customCanonical)).toBeNull()
  })
})
