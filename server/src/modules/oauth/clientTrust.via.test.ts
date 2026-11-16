import { describe, expect, it } from "bun:test"
import { oauthClientViaApp } from "@in/server/modules/oauth/clientTrust"

const CHATGPT = "https://chatgpt.com/connector_platform_oauth_redirect"
const CLAUDE = "https://claude.ai/api/mcp/auth_callback"

describe("oauthClientViaApp", () => {
  it("names hosted assistants by their verified callback, not their claimed name", () => {
    expect(oauthClientViaApp({ redirectUris: [CHATGPT], clientName: "Anything" })).toBe("chatgpt")
    expect(oauthClientViaApp({ redirectUris: [CLAUDE], clientName: null })).toBe("claude")
  })

  it("stays generic when any callback is unverified or they disagree", () => {
    expect(oauthClientViaApp({ redirectUris: [CHATGPT, "https://evil.example/cb"], clientName: "ChatGPT" })).toBe("agent")
    expect(oauthClientViaApp({ redirectUris: [CHATGPT, CLAUDE], clientName: "ChatGPT" })).toBe("agent")
    expect(oauthClientViaApp({ redirectUris: ["https://chatgpt.com/g/custom-action"], clientName: "ChatGPT" })).toBe("agent")
  })

  it("names local clients by the known agent they registered as", () => {
    const local = "http://127.0.0.1:33418/callback"
    expect(oauthClientViaApp({ redirectUris: [local], clientName: "Claude Code" })).toBe("claude-code")
    expect(oauthClientViaApp({ redirectUris: [local], clientName: "codex" })).toBe("codex")
    expect(oauthClientViaApp({ redirectUris: [local], clientName: "Inline Support" })).toBe("agent")
    expect(oauthClientViaApp({ redirectUris: [local], clientName: null })).toBe("agent")
  })
})
