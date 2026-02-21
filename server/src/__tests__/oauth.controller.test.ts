import { describe, expect, it } from "bun:test"
import { app } from "../index"
import { setupTestLifecycle, testUtils } from "./setup"
import { OauthModel } from "@in/server/db/models/oauth"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { sha256Base64Url, sha256Hex } from "@inline-chat/oauth-core"

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

  it("stores challenge token on send-email-code", async () => {
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
    authorizeUrl.searchParams.set("code_challenge", challenge)
    authorizeUrl.searchParams.set("code_challenge_method", "S256")

    const authorizeRes = await app.handle(new Request(authorizeUrl.toString(), { method: "GET" }))
    expect(authorizeRes.status).toBe(200)

    const cookie = extractSetCookieValue(authorizeRes.headers.get("set-cookie"))
    const csrf = extractHidden(await authorizeRes.text(), "csrf")

    const sendForm = new FormData()
    sendForm.set("csrf", csrf)
    sendForm.set("email", "oauth-user@example.com")

    const sendRes = await app.handle(
      new Request("http://localhost/oauth/authorize/send-email-code", {
        method: "POST",
        headers: { cookie },
        body: sendForm,
      }),
    )

    expect(sendRes.status).toBe(200)

    const authRequestId = cookie.split("=", 2)[1]!
    const authRequest = await OauthModel.getAuthRequest(authRequestId, Date.now())
    expect(authRequest?.email).toBe("oauth-user@example.com")
    expect(typeof authRequest?.challengeToken).toBe("string")
  })

  it("issues tokens from authorization_code grants persisted in postgres", async () => {
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
      scope: "messages:read spaces:read offline_access",
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

    const tokenRes = await app.handle(new Request("http://localhost/oauth/token", { method: "POST", body: tokenForm }))
    expect(tokenRes.status).toBe(200)

    const tokenBody = await tokenRes.json()
    expect(typeof tokenBody.access_token).toBe("string")
    expect(typeof tokenBody.refresh_token).toBe("string")
    expect(tokenBody.token_type).toBe("bearer")

    const accessHash = await sha256Hex(String(tokenBody.access_token))
    const refreshHash = await sha256Hex(String(tokenBody.refresh_token))

    const persistedAccess = await OauthModel.getAccessToken(accessHash, Date.now())
    const persistedRefresh = await OauthModel.getRefreshToken(refreshHash, Date.now())

    expect(persistedAccess?.grantId).toBe(grant.id)
    expect(persistedRefresh?.grantId).toBe(grant.id)
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

    const validForm = new FormData()
    validForm.set("grant_type", "refresh_token")
    validForm.set("refresh_token", refreshToken)
    validForm.set("client_id", client.clientId)
    const validRes = await app.handle(new Request("http://localhost/oauth/token", { method: "POST", body: validForm }))
    expect(validRes.status).toBe(200)

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
