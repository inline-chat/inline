import { describe, expect, it } from "bun:test"
import { app } from "../legacyServer"
import { setupTestLifecycle, testUtils } from "./setup"
import { db } from "@in/server/db"
import { users, sessions, oauthAuthRequests, oauthGrants } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { OauthModel } from "@in/server/db/models/oauth"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { sha256Base64Url } from "@inline-chat/oauth-core"
import { authRequestCookieName } from "@in/server/modules/oauth/authRequestCookie"
import { oauthConfig } from "@in/server/modules/oauth/config"
import { adminOAuthConnections } from "@in/server/modules/oauth/adminConnections"

describe("OAuth profile completion", () => {
  setupTestLifecycle()
  async function fixture(clientName = "ChatGPT") {
    const nowMs = Date.now()
    const user = await testUtils.createUser(`profile-${crypto.randomUUID()}@example.com`)
    await db.update(users).set({ firstName: "Provider", pendingSetup: true }).where(eq(users.id, user.id))
    const client = await OauthModel.createClient({ clientId: crypto.randomUUID(), redirectUris: ["https://example.com/callback"], clientName, nowMs })
    const request = await OauthModel.createAuthRequest({ id: crypto.randomUUID(), clientId: client.clientId,
      redirectUri: "https://example.com/callback", state: "test-state", scope: "messages:read",
      resource: "https://mcp.inline.chat", codeChallenge: await sha256Base64Url("test-verifier"),
      csrfToken: "test-csrf", deviceId: crypto.randomUUID(), nowMs, expiresAtMs: nowMs + 60_000 })
    const { token } = await testUtils.createSessionForUser(user.id, { deviceId: request.deviceId })
    await OauthModel.setAuthRequestInlineSession({ id: request.id, inlineUserId: user.id,
      inlineTokenEncrypted: Encryption2.encrypt(Buffer.from(token)), authMethod: "google" })
    const post = (values: Record<string, string>) => app.handle(new Request("http://localhost/oauth/authorize/consent", {
      method: "POST", headers: { cookie: `${authRequestCookieName(oauthConfig())}=${request.id}` },
      body: new URLSearchParams({ csrf: request.csrfToken, ...values }),
    }))
    const profile = (values = { name: "Test Person", username: "testperson" }) => post({ step: "profile", ...values })
    return { user, request, client, post, profile }
  }

  it("requires a profile, preserves the request, and completes consent and token exchange", async () => {
    const f = await fixture()
    const before = await OauthModel.getAuthRequest(f.request.id, Date.now())
    const profileHtml = await (await f.post({ allow_dms: "1" })).text()
    expect(profileHtml).toContain("Set up your profile")
    expect(await db.select().from(oauthGrants)).toHaveLength(0)
    const response = await f.profile()
    expect(response.status).toBe(200)
    const html = await response.text()
    expect(html).toContain("Download for macOS")
    expect(html).toContain("Get Inline for iOS")
    expect(html).toContain("Choose what to share")
    const [user] = await db.select().from(users).where(eq(users.id, f.user.id))
    expect(user?.pendingSetup).toBe(false)
    expect(user?.firstName).toBe("Test")
    expect(user?.lastName).toBe("Person")
    expect(user?.username).toBe("testperson")
    expect((await OauthModel.getAuthRequest(f.request.id, Date.now()))?.inlineTokenEncrypted).toEqual(before?.inlineTokenEncrypted)
    expect((await f.profile({ name: "Changed", username: "changed" })).status).toBe(200)
    expect(await db.select().from(oauthGrants)).toHaveLength(0)
    const consent = await f.post({ allow_dms: "1" })
    expect(consent.status).toBe(302)
    const code = new URL(consent.headers.get("location")!).searchParams.get("code")!
    const exchanged = await app.handle(new Request("http://localhost/oauth/token", { method: "POST",
      body: new URLSearchParams({ grant_type: "authorization_code", code, client_id: f.client.clientId,
        redirect_uri: f.request.redirectUri, code_verifier: "test-verifier" }) }))
    expect(exchanged.status).toBe(200)
    expect((await exchanged.json()).refresh_token).toBeString()
    expect((await adminOAuthConnections([f.user.id])).get(f.user.id)).toEqual(["chatgpt"])
  })

  it("sanitizes profile handles and rejects normalized collisions and invalid results", async () => {
    const f = await fixture()
    expect((await f.profile({ name: "Test", username: "Mixed.Case@example.com" })).status).toBe(200)
    expect((await db.select().from(users).where(eq(users.id, f.user.id)))[0]?.username).toBe("Mixed_Case")
    const other = await fixture()
    for (const username of ["mixed-case", "@@@", "💥", "a".repeat(65)]) {
      expect((await other.profile({ name: "Test", username })).status).toBe(400)
    }
    const [unchanged] = await db.select().from(users).where(eq(users.id, other.user.id))
    expect(unchanged?.username).toBeNull()
    expect(unchanged?.pendingSetup).toBe(true)
  })

  it("rejects CSRF, invalid names and taken usernames without completing setup", async () => {
    const f = await fixture()
    const other = await testUtils.createUser("other@example.com")
    await db.update(users).set({ username: "taken" }).where(eq(users.id, other.id))
    expect((await f.post({ step: "profile", csrf: "wrong", name: "Test", username: "valid" })).status).toBe(400)
    expect((await f.profile({ name: " ", username: "x" })).status).toBe(400)
    const conflict = await f.profile({ name: "<script>name</script>", username: "taken" })
    expect(conflict.status).toBe(400)
    const html = await conflict.text()
    expect(html).toContain("username is already taken")
    expect(html).toContain("&lt;script&gt;")
    expect(html).not.toContain("<script>name</script>")
    expect((await db.select().from(users).where(eq(users.id, f.user.id)))[0]?.pendingSetup).toBe(true)
    expect(await db.select().from(oauthGrants)).toHaveLength(0)
  })

  it("hides downloads for prior sessions and generic MCP and hides revoked grants in admin", async () => {
    const returning = await fixture()
    const prior = await testUtils.createSessionForUser(returning.user.id, { clientType: "macos" })
    await db.update(sessions).set({ date: null }).where(eq(sessions.id, prior.session.id))
    const generic = await fixture("Example MCP")
    for (const [index, f] of [returning, generic].entries()) {
      const response = await f.profile({ name: "Test", username: `testuser${index}` })
      expect(response.status).toBe(200)
      expect(await response.text()).not.toContain("Download for macOS")
    }
    expect((await generic.post({ allow_dms: "1" })).status).toBe(302)
    expect((await adminOAuthConnections([generic.user.id])).get(generic.user.id)).toEqual(["mcp"])
    await db.update(oauthGrants).set({ revokedAt: new Date() }).where(eq(oauthGrants.inlineUserId, generic.user.id))
    expect((await adminOAuthConnections([generic.user.id])).has(generic.user.id)).toBe(false)
  })

  it("rejects revoked sessions and expired requests before saving", async () => {
    const f = await fixture()
    await db.update(sessions).set({ revoked: new Date() }).where(eq(sessions.userId, f.user.id))
    expect((await f.profile()).status).toBe(401)
    await db.update(oauthAuthRequests).set({ expiresAt: new Date(0) }).where(eq(oauthAuthRequests.id, f.request.id))
    expect((await f.profile()).status).toBe(400)
    expect((await db.select().from(users).where(eq(users.id, f.user.id)))[0]?.pendingSetup).toBe(true)
  })
})
