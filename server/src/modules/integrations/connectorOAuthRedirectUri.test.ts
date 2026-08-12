import { describe, expect, test } from "bun:test"
import { connectorOAuthRedirectUri } from "./connectorOAuthRedirectUri"

describe("connector OAuth redirect URI", () => {
  test("preserves registered local defaults", () => {
    expect(connectorOAuthRedirectUri("notion", { nodeEnv: "development" }))
      .toBe("http://localhost:8000/integrations/notion/callback")
    expect(connectorOAuthRedirectUri("linear", { nodeEnv: "development" }))
      .toBe("http://127.0.0.1:8000/integrations/linear/callback")
  })

  test("uses one configurable development origin for device-accessible callbacks", () => {
    expect(connectorOAuthRedirectUri("notion", {
      nodeEnv: "development",
      developmentBaseUrl: "https://inline-dev.example.test",
    })).toBe("https://inline-dev.example.test/integrations/notion/callback")
    expect(connectorOAuthRedirectUri("linear", {
      nodeEnv: "development",
      developmentBaseUrl: "https://inline-dev.example.test",
    })).toBe("https://inline-dev.example.test/integrations/linear/callback")
  })

  test("keeps the production callback canonical", () => {
    expect(connectorOAuthRedirectUri("notion", {
      nodeEnv: "production",
      developmentBaseUrl: "https://attacker.example.test",
    })).toBe("https://api.inline.chat/integrations/notion/callback")
  })

  test("rejects non-HTTP callback origins", () => {
    expect(() => connectorOAuthRedirectUri("linear", {
      nodeEnv: "development",
      developmentBaseUrl: "in://callback",
    })).toThrow("absolute HTTP(S) origin")
  })
})
