import { describe, expect, it, spyOn } from "bun:test"
import { app } from "../legacyServer"
import { setupTestLifecycle, testUtils } from "./setup"
import { OauthModel } from "@in/server/db/models/oauth"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { sha256Base64Url, sha256Hex } from "@inline-chat/oauth-core"
import { db } from "@in/server/db"
import { oauthAuthRequests, oauthAuthCodes, oauthGrants } from "@in/server/db/schema"
import { eq, inArray } from "drizzle-orm"
import { authRequestCookieName } from "@in/server/modules/oauth/authRequestCookie"
import { oauthConfig } from "@in/server/modules/oauth/config"
import {
  hostedLoginChooser,
  hostedLoginVerificationForm,
} from "@in/server/modules/auth/hostedLogin/httpHandlers"

function extractSetCookieValue(setCookie: string | null): string {
  if (!setCookie) throw new Error("missing set-cookie")
  return setCookie.split(";", 1)[0]!
}

function extractHidden(html: string, name: string): string {
  const regex = new RegExp(`name=\\"${name}\\" value=\\"([^\\"]+)\\"`)
  const match = html.match(regex)
  if (!match) throw new Error(`missing hidden input: ${name}`)
  return match[1]!
}

describe("OAuth controller", () => {
  setupTestLifecycle()

  async function consentFixture() {
    const nowMs = Date.now()
    const user = await testUtils.createUser(`consent-${crypto.randomUUID()}@example.com`)
    const client = await OauthModel.createClient({
      clientId: crypto.randomUUID(), redirectUris: ["https://example.com/callback"], clientName: "consent-test", nowMs,
    })
    const request = await OauthModel.createAuthRequest({
      id: crypto.randomUUID(), clientId: client.clientId, redirectUri: "https://example.com/callback",
      state: "state", scope: "messages:read", resource: "https://mcp.inline.chat",
      codeChallenge: await sha256Base64Url("test-verifier"), csrfToken: "test-csrf", deviceId: crypto.randomUUID(),
      nowMs, expiresAtMs: nowMs + 60_000,
    })
    const { token } = await testUtils.createSessionForUser(user.id)
    await OauthModel.setAuthRequestInlineSession({
      id: request.id,
      inlineUserId: user.id,
      inlineTokenEncrypted: Encryption2.encrypt(Buffer.from(token, "utf8")),
      authMethod: "email",
    })
    const submit = () => app.handle(new Request("http://localhost/oauth/authorize/consent", {
      method: "POST",
      headers: { cookie: `${authRequestCookieName(oauthConfig())}=${request.id}` },
      body: new URLSearchParams({ csrf: request.csrfToken, allow_dms: "1" }),
    }))
    return { request, client, submit }
  }

  it("preserves hosted backing credentials through continuation and consent", async () => {
    const { request, submit } = await consentFixture()
    const before = await OauthModel.getAuthRequest(request.id, Date.now())
    const response = await app.handle(new Request("http://localhost/oauth/authorize/continue", {
      headers: { cookie: `${authRequestCookieName(oauthConfig())}=${request.id}` },
    }))
    expect(response.status).toBe(200)
    const after = await OauthModel.getAuthRequest(request.id, Date.now())
    expect(after?.inlineTokenEncrypted).toEqual(before?.inlineTokenEncrypted)
    expect((await submit()).status).toBe(302)
  })

  it("rejects consent without backing credentials and preserves the request", async () => {
    const { request, client, submit } = await consentFixture()
    await db.update(oauthAuthRequests).set({ inlineTokenEncrypted: null })
      .where(eq(oauthAuthRequests.id, request.id))
    expect((await submit()).status).toBe(400)
    expect(await db.select().from(oauthGrants).where(eq(oauthGrants.clientId, client.clientId))).toHaveLength(0)
    expect(await db.select().from(oauthAuthCodes).where(eq(oauthAuthCodes.clientId, client.clientId))).toHaveLength(0)
    expect(await OauthModel.getAuthRequest(request.id, Date.now())).not.toBeNull()
  })

  it("issues only one grant and code for concurrent consent submissions", async () => {
    const { request, client, submit } = await consentFixture()
    const responses = await Promise.all([submit(), submit()])
    expect(responses.map((response) => response.status).sort()).toEqual([302, 400])
    expect(await db.select().from(oauthGrants).where(eq(oauthGrants.clientId, client.clientId))).toHaveLength(1)
    expect(await db.select().from(oauthAuthCodes).where(eq(oauthAuthCodes.clientId, client.clientId))).toHaveLength(1)
    expect(await OauthModel.getAuthRequest(request.id, Date.now())).toBeNull()
  })

  it("rolls back consent consumption and the grant when code issuance fails", async () => {
    const { request, client, submit } = await consentFixture()
    const issueCode = spyOn(OauthModel, "createAuthCode").mockRejectedValueOnce(new Error("injected issuance failure"))
    try {
      expect((await submit()).status).toBe(500)
    } finally {
      issueCode.mockRestore()
    }
    expect(await OauthModel.getAuthRequest(request.id, Date.now())).not.toBeNull()
    expect(await db.select().from(oauthGrants).where(eq(oauthGrants.clientId, client.clientId))).toHaveLength(0)
    expect((await submit()).status).toBe(302)
  })

  it("cleans expired OAuth rows with typed timestamp predicates", async () => {
    const nowMs = Date.now()
    const client = await OauthModel.createClient({
      clientId: crypto.randomUUID(),
      redirectUris: ["https://example.com/callback"],
      clientName: "cleanup-client",
      nowMs,
    })
    const expiredId = crypto.randomUUID()
    const liveId = crypto.randomUUID()

    for (const [id, expiresAtMs] of [
      [expiredId, nowMs - 1_000],
      [liveId, nowMs + 60_000],
    ] as const) {
      await OauthModel.createAuthRequest({
        id,
        clientId: client.clientId,
        redirectUri: "https://example.com/callback",
        state: `state-${id}`,
        scope: "messages:read",
        resource: "https://mcp.inline.chat",
        codeChallenge: `challenge-${id}`,
        csrfToken: `csrf-${id}`,
        deviceId: `device-${id}`,
        nowMs,
        expiresAtMs,
      })
    }

    await expect(OauthModel.cleanupExpired(nowMs)).resolves.toBeUndefined()

    const remaining = await db
      .select({ id: oauthAuthRequests.id })
      .from(oauthAuthRequests)
      .where(inArray(oauthAuthRequests.id, [expiredId, liveId]))
    expect(remaining).toEqual([{ id: liveId }])
  })

  it("renders the hosted login chooser without stranding a second user agent", async () => {
    const registerRes = await app.handle(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ redirect_uris: ["https://example.com/callback"] }),
      }),
    )

    expect(registerRes.status).toBe(201)
    const registerBody = await registerRes.json()
    const clientId = String(registerBody.client_id)

    const verifier = "oauth-verifier"
    const challenge = await sha256Base64Url(verifier)

    const authorizeUrl = new URL("http://localhost/oauth/authorize")
    authorizeUrl.searchParams.set("response_type", "code")
    authorizeUrl.searchParams.set("client_id", clientId)
    authorizeUrl.searchParams.set("redirect_uri", "https://example.com/callback")
    authorizeUrl.searchParams.set("state", "state-1")
    authorizeUrl.searchParams.set("scope", "messages:read spaces:read offline_access")
    authorizeUrl.searchParams.set("resource", "https://mcp.inline.chat/mcp/v2")
    authorizeUrl.searchParams.set("code_challenge", challenge)
    authorizeUrl.searchParams.set("code_challenge_method", "S256")

    const authorizeRes = await app.handle(new Request(authorizeUrl.toString(), { method: "GET" }))
    expect(authorizeRes.status).toBe(303)
    const oauthCookie = extractSetCookieValue(authorizeRes.headers.get("set-cookie"))
    const authRequestId = oauthCookie.split("=", 2)[1]!
    expect((await OauthModel.getAuthRequest(authRequestId, Date.now()))?.resource).toBe("https://mcp.inline.chat")
    expect(authorizeRes.headers.get("set-cookie")).toContain("Path=/;")
    const location = authorizeRes.headers.get("location")
    expect(location).toContain("/v1/auth/login?capability=")

    // Link resolvers and security preflights may visit the URL without sharing
    // their cookies with the user's browser. The pending capability must remain
    // sufficient for the real browser to establish its own session.
    const preflightRes = await app.handle(new Request(location!))
    expect(preflightRes.status).toBe(200)

    const establishRes = await app.handle(new Request(location!, { headers: { cookie: oauthCookie } }))
    expect(establishRes.status).toBe(200)
    expect(establishRes.headers.get("referrer-policy")).toBe("no-referrer")
    const hostedCookies = establishRes.headers.getSetCookie().map(extractSetCookieValue)
    expect(hostedCookies).toHaveLength(3)
    expect(hostedCookies).toContain(oauthCookie)
    const cookie = [oauthCookie, ...hostedCookies].join("; ")

    const chooserHtml = await establishRes.text()
    expect(chooserHtml).toContain('href="/v1/auth/login?method=email"')
    expect(chooserHtml).toContain('href="/v1/auth/login?method=phone"')
    expect(chooserHtml).toContain("provider=google&amp;purpose=hosted_login")
    expect(chooserHtml).toContain("provider=apple&amp;purpose=hosted_login")
    expect(chooserHtml.match(/class="method-button"/g)).toHaveLength(4)
    expect(chooserHtml).not.toContain("Confirm that this code matches")
    expect(chooserHtml).not.toContain("CLI code")
    expect(chooserHtml).not.toContain('name="email"')
    expect(chooserHtml).not.toContain('name="phone_number"')
    expect(chooserHtml).not.toContain('name="invite_code"')
    expect(chooserHtml).not.toContain("<script")

    const chooserRes = await app.handle(new Request("http://localhost/v1/auth/login", { headers: { cookie } }))
    expect(chooserRes.status).toBe(200)

    const emailRes = await app.handle(new Request("http://localhost/v1/auth/login?method=email", {
      headers: { cookie },
    }))
    expect(emailRes.status).toBe(200)
    const emailHtml = await emailRes.text()
    expect(extractHidden(emailHtml, "csrf").length).toBeGreaterThan(20)
    expect(emailHtml).toContain('action="/v1/auth/login/send-email-code"')
    expect(emailHtml).toContain('name="email"')
    expect(emailHtml).not.toContain('name="phone_number"')
    expect(emailHtml).not.toContain("CLI code")
    expect(emailHtml).not.toContain('name="invite_code"')

    const phoneRes = await app.handle(new Request("http://localhost/v1/auth/login?method=phone", {
      headers: { cookie },
    }))
    expect(phoneRes.status).toBe(200)
    const phoneHtml = await phoneRes.text()
    expect(extractHidden(phoneHtml, "csrf").length).toBeGreaterThan(20)
    expect(phoneHtml).toContain('action="/v1/auth/login/send-sms-code"')
    expect(phoneHtml).toContain('name="phone_number"')
    expect(phoneHtml).not.toContain('name="email"')
    expect(phoneHtml).not.toContain("CLI code")
    expect(phoneHtml).not.toContain('name="invite_code"')
  })

  it("shows client-bound proof only to the Inline CLI login target", async () => {
    const oauthChooserHtml = await hostedLoginChooser("oauth_authorization", "123456").text()
    expect(oauthChooserHtml).not.toContain("Confirm that this code matches")
    expect(oauthChooserHtml).not.toContain("123456")

    const cliChooserHtml = await hostedLoginChooser("inline_protocol_key", "654321").text()
    expect(cliChooserHtml).toContain("Confirm that this code matches the one shown in your Inline CLI.")
    expect(cliChooserHtml).toContain("654321")

    const oauthHtml = await hostedLoginVerificationForm(
      "oauth_authorization",
      "123456",
      "csrf-token",
      "email",
      "person@example.com",
    ).text()
    expect(oauthHtml).toContain("We sent a 6-digit code to person@example.com.")
    expect(oauthHtml).not.toContain("CLI code")
    expect(oauthHtml).not.toContain("123456")
    expect(oauthHtml).not.toContain('name="invite_code"')

    const cliHtml = await hostedLoginVerificationForm(
      "inline_protocol_key",
      "654321",
      "csrf-token",
      "email",
      "person@example.com",
    ).text()
    expect(cliHtml).toContain("CLI code: <strong>654321</strong>")
    expect(cliHtml).toContain('name="invite_code"')
  })

  it("issues two-hour access and 180-day refresh tokens without requiring offline_access", async () => {
    const nowMs = Date.now()
    const user = await testUtils.createUser("oauth-token-user@example.com")
    const client = await OauthModel.createClient({
      clientId: crypto.randomUUID(),
      redirectUris: ["https://example.com/callback"],
      clientName: "test",
      nowMs,
    })

    const grant = await OauthModel.createGrant({
      id: crypto.randomUUID(),
      clientId: client.clientId,
      inlineUserId: user.id,
      scope: "messages:read spaces:read",
      resource: "https://mcp.inline.chat",
      spaceIds: [1n, 2n],
      allowDms: true,
      allowHomeThreads: true,
      inlineTokenEncrypted: Encryption2.encrypt(Buffer.from("1001:inline-session-token", "utf8")),
      nowMs,
    })

    const verifier = "verifier-123"
    const challenge = await sha256Base64Url(verifier)
    const authCode = "mcp_ac_test-code"

    await OauthModel.createAuthCode({
      code: authCode,
      grantId: grant.id,
      clientId: client.clientId,
      redirectUri: "https://example.com/callback",
      codeChallenge: challenge,
      nowMs,
      expiresAtMs: nowMs + 5 * 60_000,
    })

    const tokenForm = new FormData()
    tokenForm.set("grant_type", "authorization_code")
    tokenForm.set("code", authCode)
    tokenForm.set("client_id", client.clientId)
    tokenForm.set("redirect_uri", "https://example.com/callback")
    tokenForm.set("code_verifier", verifier)
    tokenForm.set("resource", "https://mcp.inline.chat/mcp/v2")

    const tokenRes = await app.handle(new Request("http://localhost/oauth/token", { method: "POST", body: tokenForm }))
    expect(tokenRes.status).toBe(200)

    const tokenBody = await tokenRes.json()
    expect(typeof tokenBody.access_token).toBe("string")
    expect(typeof tokenBody.refresh_token).toBe("string")
    expect(tokenBody.token_type).toBe("bearer")
    expect(tokenBody.expires_in).toBe(2 * 60 * 60)
    expect(tokenRes.headers.get("pragma")).toBe("no-cache")

    const accessHash = await sha256Hex(String(tokenBody.access_token))
    const refreshHash = await sha256Hex(String(tokenBody.refresh_token))

    const persistedAccess = await OauthModel.getAccessToken(accessHash, Date.now())
    const persistedRefresh = await OauthModel.getRefreshToken(refreshHash, Date.now())

    expect(persistedAccess?.grantId).toBe(grant.id)
    expect(persistedRefresh?.grantId).toBe(grant.id)
    expect(persistedAccess && persistedAccess.expiresAtMs - persistedAccess.createdAtMs).toBe(2 * 60 * 60_000)
    expect(persistedRefresh && persistedRefresh.expiresAtMs - persistedRefresh.createdAtMs).toBe(180 * 24 * 60 * 60_000)
  })

  it("requires matching client_id for refresh_token grants", async () => {
    const nowMs = Date.now()
    const user = await testUtils.createUser("oauth-refresh-user@example.com")
    const client = await OauthModel.createClient({
      clientId: crypto.randomUUID(),
      redirectUris: ["https://example.com/callback"],
      clientName: "refresh-client",
      nowMs,
    })
    const otherClient = await OauthModel.createClient({
      clientId: crypto.randomUUID(),
      redirectUris: ["https://example.com/callback"],
      clientName: "other-client",
      nowMs,
    })

    const grant = await OauthModel.createGrant({
      id: crypto.randomUUID(),
      clientId: client.clientId,
      inlineUserId: user.id,
      scope: "messages:read spaces:read offline_access",
      resource: "https://mcp.inline.chat",
      spaceIds: [1n],
      allowDms: false,
      allowHomeThreads: false,
      inlineTokenEncrypted: Encryption2.encrypt(Buffer.from("1003:inline-session-token", "utf8")),
      nowMs,
    })

    const refreshToken = "mcp_rt_client_binding_test"
    await OauthModel.createRefreshToken({
      tokenHash: await sha256Hex(refreshToken),
      grantId: grant.id,
      nowMs,
      expiresAtMs: nowMs + 60_000,
    })

    const missingClientIdForm = new FormData()
    missingClientIdForm.set("grant_type", "refresh_token")
    missingClientIdForm.set("refresh_token", refreshToken)
    const missingClientIdRes = await app.handle(
      new Request("http://localhost/oauth/token", { method: "POST", body: missingClientIdForm }),
    )
    expect(missingClientIdRes.status).toBe(400)
    expect((await missingClientIdRes.json()).error).toBe("missing_client_id")

    const wrongClientIdForm = new FormData()
    wrongClientIdForm.set("grant_type", "refresh_token")
    wrongClientIdForm.set("refresh_token", refreshToken)
    wrongClientIdForm.set("client_id", otherClient.clientId)
    const wrongClientIdRes = await app.handle(
      new Request("http://localhost/oauth/token", { method: "POST", body: wrongClientIdForm }),
    )
    expect(wrongClientIdRes.status).toBe(400)
    expect((await wrongClientIdRes.json()).error).toBe("invalid_grant")

    const refreshRequest = () => {
      const form = new FormData()
      form.set("grant_type", "refresh_token")
      form.set("refresh_token", refreshToken)
      form.set("client_id", client.clientId)
      form.set("resource", "https://mcp.inline.chat/mcp/v2")
      return app.handle(new Request("http://localhost/oauth/token", { method: "POST", body: form }))
    }
    const refreshResponses = await Promise.all([refreshRequest(), refreshRequest()])
    expect(refreshResponses.map((response) => response.status).sort()).toEqual([200, 400])

    const validRes = refreshResponses.find((response) => response.status === 200)!
    const rejectedRes = refreshResponses.find((response) => response.status === 400)!
    expect((await rejectedRes.json()).error).toBe("invalid_grant")
    const validBody = await validRes.json()
    expect(typeof validBody.access_token).toBe("string")
    expect(typeof validBody.refresh_token).toBe("string")
    expect(validBody.token_type).toBe("bearer")
  })

  it("rejects introspection without shared secret header", async () => {
    const form = new FormData()
    form.set("token", "mcp_at_test_token")

    const res = await app.handle(new Request("http://localhost/oauth/introspect", { method: "POST", body: form }))
    expect(res.status).toBe(401)
    expect((await res.json()).error).toBe("unauthorized")
  })

  it("revokes grants and refresh tokens from revoke endpoint", async () => {
    const nowMs = Date.now()
    const user = await testUtils.createUser("oauth-revoke-user@example.com")
    const client = await OauthModel.createClient({
      clientId: crypto.randomUUID(),
      redirectUris: ["https://example.com/callback"],
      clientName: "test",
      nowMs,
    })

    const grant = await OauthModel.createGrant({
      id: crypto.randomUUID(),
      clientId: client.clientId,
      inlineUserId: user.id,
      scope: "messages:read spaces:read offline_access",
      resource: "https://mcp.inline.chat",
      spaceIds: [1n],
      allowDms: false,
      allowHomeThreads: false,
      inlineTokenEncrypted: Encryption2.encrypt(Buffer.from("1002:inline-session-token", "utf8")),
      nowMs,
    })

    const refreshToken = "mcp_rt_revoke_test"
    await OauthModel.createRefreshToken({
      tokenHash: await sha256Hex(refreshToken),
      grantId: grant.id,
      nowMs,
      expiresAtMs: nowMs + 60_000,
    })

    const form = new FormData()
    form.set("token", refreshToken)

    const revokeRes = await app.handle(new Request("http://localhost/oauth/revoke", { method: "POST", body: form }))
    expect(revokeRes.status).toBe(200)

    const revokedGrant = await OauthModel.getGrant(grant.id)
    expect(revokedGrant?.revokedAtMs).not.toBeNull()

    const revokedRefresh = await OauthModel.getRefreshToken(await sha256Hex(refreshToken), Date.now())
    expect(revokedRefresh).toBeNull()
  })
})
