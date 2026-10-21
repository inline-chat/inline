import { describe, expect, it } from "bun:test"
import { eq } from "drizzle-orm"
import { app } from "../legacyServer"
import { setupTestLifecycle, testUtils } from "./setup"
import { db } from "@in/server/db"
import { members, oauthGrants, sessions, users } from "@in/server/db/schema"
import { OauthModel } from "@in/server/db/models/oauth"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { sha256Base64Url } from "@inline-chat/oauth-core"
import { authRequestCookieName } from "@in/server/modules/oauth/authRequestCookie"
import { oauthConfig } from "@in/server/modules/oauth/config"
import { oauthClientTrust } from "@in/server/modules/oauth/clientTrust"

describe("OAuth consent client trust", () => {
  setupTestLifecycle()

  async function fixture(redirectUri: string, clientName = "ChatGPT") {
    const nowMs = Date.now()
    const user = await testUtils.createUser(`consent-${crypto.randomUUID()}@example.com`)
    await db.update(users).set({ firstName: "Test", username: `consent${user.id}`, pendingSetup: false })
      .where(eq(users.id, user.id))
    const space = await testUtils.createSpace("Consent Space")
    if (!space) throw new Error("Failed to create space")
    await db.insert(members).values({ spaceId: space.id, userId: user.id, role: "member" })
    const client = await OauthModel.createClient({ clientId: crypto.randomUUID(), redirectUris: [redirectUri], clientName, nowMs })
    const request = await OauthModel.createAuthRequest({
      id: crypto.randomUUID(), clientId: client.clientId, redirectUri, state: "state-1",
      scope: "messages:read messages:write offline_access", resource: "https://mcp.inline.chat",
      codeChallenge: await sha256Base64Url("verifier"), csrfToken: "csrf-1", deviceId: crypto.randomUUID(),
      nowMs, expiresAtMs: nowMs + 60_000,
    })
    const { token, session } = await testUtils.createSessionForUser(user.id, { deviceId: request.deviceId })
    await OauthModel.setAuthRequestInlineSession({
      id: request.id, inlineUserId: user.id, inlineTokenEncrypted: Encryption2.encrypt(Buffer.from(token)), authMethod: "email",
    })
    const cookie = `${authRequestCookieName(oauthConfig())}=${request.id}`
    const consentPage = async () => (await app.handle(new Request("http://localhost/oauth/authorize/continue", {
      headers: { cookie },
    }))).text()
    const post = (values: Record<string, string>) => app.handle(new Request("http://localhost/oauth/authorize/consent", {
      method: "POST", headers: { cookie }, body: new URLSearchParams({ csrf: "csrf-1", ...values }),
    }))
    return { user, session, consentPage, post }
  }

  it("classifies trust by redirect destination, never by client name", () => {
    expect(oauthClientTrust("https://chatgpt.com/connector_platform_oauth_redirect").verified).toBe(true)
    expect(oauthClientTrust("https://claude.ai/api/mcp/auth_callback").verified).toBe(true)
    expect(oauthClientTrust("http://127.0.0.1:53682/callback")).toMatchObject({ verified: true, loopback: true })
    expect(oauthClientTrust("https://chatgpt.com.evil.example/cb").verified).toBe(false)
    expect(oauthClientTrust("https://evil.example/cb")).toMatchObject({ verified: false, host: "evil.example" })
  })

  it("verifies only the exact assistant callback URIs, not every path on their hosts", () => {
    for (const uri of [
      "https://chatgpt.com/connector_platform_oauth_redirect",
      "https://claude.ai/api/mcp/auth_callback",
      "https://claude.com/api/mcp/auth_callback",
      "https://ChatGPT.com/connector_platform_oauth_redirect",
      "https://chatgpt.com:443/connector_platform_oauth_redirect",
    ]) {
      expect(oauthClientTrust(uri)).toMatchObject({ verified: true, loopback: false })
    }
    for (const uri of [
      // Custom-GPT action callbacks: any ChatGPT user can create one.
      "https://chatgpt.com/aip/g-0123456789abcdef/oauth/callback",
      "https://claude.ai/some/other/callback",
      "https://chatgpt.com/connector_platform_oauth_redirect/",
      "https://chatgpt.com/connector_platform_oauth_redirect?next=https://evil.example",
      "https://chatgpt.com/connector_platform_oauth_redirect#fragment",
      "https://chatgpt.com:8443/connector_platform_oauth_redirect",
      "https://user@chatgpt.com/connector_platform_oauth_redirect",
      "http://chatgpt.com/connector_platform_oauth_redirect",
      "https://claude.ai/API/mcp/auth_callback",
    ]) {
      expect(oauthClientTrust(uri)).toMatchObject({ verified: false, loopback: false })
    }
    // Loopback is unchanged: any port and path on this computer.
    expect(oauthClientTrust("http://localhost:8976/oauth/callback")).toMatchObject({ verified: true, loopback: true, host: "this computer" })
    expect(oauthClientTrust("http://[::1]:7777/cb?x=1")).toMatchObject({ verified: true, loopback: true })
    expect(oauthClientTrust("https://127.0.0.1/cb")).toMatchObject({ verified: false, loopback: false })
  })

  it("treats a client named ChatGPT with a custom-GPT callback as unverified", async () => {
    const f = await fixture("https://chatgpt.com/aip/g-0123456789abcdef/oauth/callback", "ChatGPT")
    const html = await f.consentPage()
    expect(html).toContain("Unverified app")
    expect(html).toContain("Inline hasn’t verified this app.")
    expect(html).toContain("<strong>chatgpt.com</strong>")
    expect(html).not.toContain(" checked")
  })

  it("warns about an unverified app, names where access goes, and pre-selects nothing", async () => {
    const f = await fixture("https://evil.example/cb")
    const html = await f.consentPage()
    expect(html).toContain("Unverified app")
    expect(html).toContain("Inline hasn’t verified this app.")
    expect(html).toContain("<strong>evil.example</strong>")
    expect(html).toContain("Send messages and reactions as you")
    expect(html).not.toContain(" checked")
  })

  it("keeps the familiar pre-selected consent for verified apps", async () => {
    const f = await fixture("https://chatgpt.com/connector_platform_oauth_redirect")
    const html = await f.consentPage()
    expect(html).toContain("Connect ChatGPT")
    expect(html).toContain(" checked")
    expect(html).not.toContain("Inline hasn’t verified this app.")
  })

  it("cancelling an unverified app grants nothing, revokes the sign-in session, and does not redirect", async () => {
    const f = await fixture("https://evil.example/cb")
    const response = await f.post({ decision: "deny" })
    expect(response.status).toBe(200)
    expect(response.headers.get("location")).toBeNull()
    expect(await response.text()).toContain("No access granted")
    expect(await db.select().from(oauthGrants).where(eq(oauthGrants.inlineUserId, f.user.id))).toHaveLength(0)
    const [session] = await db.select().from(sessions).where(eq(sessions.id, f.session.id))
    expect(session?.revoked).not.toBeNull()
  })

  it("cancelling a verified app returns access_denied to the app", async () => {
    const f = await fixture("https://chatgpt.com/connector_platform_oauth_redirect")
    const response = await f.post({ decision: "deny" })
    expect(response.status).toBe(302)
    const location = new URL(response.headers.get("location")!)
    expect(location.searchParams.get("error")).toBe("access_denied")
    expect(location.searchParams.get("state")).toBe("state-1")
    expect(location.searchParams.get("code")).toBeNull()
  })
})
