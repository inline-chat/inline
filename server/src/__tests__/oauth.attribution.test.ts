import { beforeEach, describe, expect, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { OauthModel } from "@in/server/db/models/oauth"
import {
  integrationSpanAttributes,
  normalizeOAuthClientName,
  oauthClientLabel,
  resetOAuthAttributionCacheForTests,
  resolveOAuthAttribution,
} from "@in/server/modules/oauth/attribution"

setupTestLifecycle()

const createGrant = async (input: { userId: number; clientName: string; redirectUri: string }) => {
  const nowMs = Date.now()
  const client = await OauthModel.createClient({
    clientId: crypto.randomUUID(),
    redirectUris: [input.redirectUri],
    clientName: input.clientName,
    nowMs,
  })
  return await OauthModel.createGrant({
    id: crypto.randomUUID(),
    clientId: client.clientId,
    inlineUserId: input.userId,
    scope: "messages:read",
    resource: "https://mcp.inline.chat",
    spaceIds: [],
    allowDms: true,
    allowHomeThreads: true,
    nowMs,
  })
}

describe("OAuth client labels", () => {
  test("name verified assistants by callback, and self-named clients as other:<name>", () => {
    expect(oauthClientLabel({ redirectUris: ["https://chatgpt.com/connector_platform_oauth_redirect"], clientName: "ChatGPT" }))
      .toEqual({ app: "chatgpt", name: "chatgpt", label: "chatgpt" })
    expect(oauthClientLabel({ redirectUris: ["http://127.0.0.1:8089/callback"], clientName: "msgvault" }))
      .toEqual({ app: "agent", name: "msgvault", label: "other:msgvault" })
    // A web client calling itself ChatGPT never merges with the verified one.
    expect(oauthClientLabel({ redirectUris: ["https://evil.example/cb"], clientName: "ChatGPT" }).label).toBe("other:chatgpt")
    // A local agent known by name keeps its agent id, like "Sent via".
    expect(oauthClientLabel({ redirectUris: ["http://localhost:3000/cb"], clientName: "Claude Code" }).label).toBe("claude-code")
  })

  test("normalize registration names into bounded labels", () => {
    expect(normalizeOAuthClientName("  Claude Code (Craft Agent) ")).toBe("claude-code-craft-agent")
    expect(normalizeOAuthClientName("x'*/; drop table users")).toBe("x-drop-table-users")
    expect(normalizeOAuthClientName(null)).toBe("unnamed")
    expect(normalizeOAuthClientName("🌴")).toBe("unnamed")
    expect(normalizeOAuthClientName("a".repeat(80))).toHaveLength(32)
  })
})

describe("OAuth grant attribution", () => {
  beforeEach(() => resetOAuthAttributionCacheForTests())

  test("resolves a live grant for its own user only", async () => {
    const owner = await testUtils.createUser(`attr-owner-${crypto.randomUUID()}@example.com`)
    const other = await testUtils.createUser(`attr-other-${crypto.randomUUID()}@example.com`)
    const grant = await createGrant({ userId: owner.id, clientName: "msgvault", redirectUri: "http://127.0.0.1:8089/callback" })

    expect(await resolveOAuthAttribution(grant.id, owner.id)).toEqual({
      app: "agent",
      name: "msgvault",
      label: "other:msgvault",
      grantId: grant.id,
      clientId: grant.clientId,
    })
    expect(await resolveOAuthAttribution(grant.id, other.id)).toBeNull()
    expect(await resolveOAuthAttribution(grant.id.toUpperCase(), owner.id)).not.toBeNull()
  })

  test("ignores malformed, unknown and revoked grants", async () => {
    const owner = await testUtils.createUser(`attr-revoked-${crypto.randomUUID()}@example.com`)
    const grant = await createGrant({ userId: owner.id, clientName: "ChatGPT", redirectUri: "https://chatgpt.com/connector_platform_oauth_redirect" })

    expect(await resolveOAuthAttribution(null, owner.id)).toBeNull()
    expect(await resolveOAuthAttribution("not-a-grant", owner.id)).toBeNull()
    expect(await resolveOAuthAttribution(crypto.randomUUID(), owner.id)).toBeNull()
    expect((await resolveOAuthAttribution(grant.id, owner.id))?.label).toBe("chatgpt")

    await OauthModel.revokeGrant(grant.id, Date.now())
    // Cached for a minute per process; a fresh lookup sees the revocation.
    expect((await resolveOAuthAttribution(grant.id, owner.id))?.label).toBe("chatgpt")
    expect(await resolveOAuthAttribution(grant.id, owner.id, Date.now() + 61_000)).toBeNull()
  })
})

describe("integration span attributes", () => {
  test("never use keys Sentry scrubs by default", () => {
    const attributes = integrationSpanAttributes({
      label: { app: "agent", name: "msgvault", label: "other:msgvault" },
      clientId: "c",
      grantId: "g",
    })
    expect(attributes["integration.client"]).toBe("other:msgvault")
    for (const key of Object.keys(attributes)) {
      expect(key).not.toMatch(/auth|token|secret|passw|credential|api_?key|private|session/i)
    }
  })
})
