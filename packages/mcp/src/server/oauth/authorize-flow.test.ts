import { beforeEach, describe, expect, it, vi } from "vitest"
import { createApp } from "../app"

function base64Url(bytes: Uint8Array): string {
  return Buffer.from(bytes)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "")
}

async function pkceChallenge(verifier: string): Promise<string> {
  const data = new TextEncoder().encode(verifier)
  const digest = await crypto.subtle.digest("SHA-256", data)
  return base64Url(new Uint8Array(digest))
}

function extractSetCookieValue(setCookie: string | null): string {
  if (!setCookie) throw new Error("missing set-cookie")
  return setCookie.split(";", 1)[0]!
}

function extractHidden(html: string, name: string): string {
  const re = new RegExp(`name=\\"${name}\\" value=\\"([^\\"]+)\\"`)
  const m = html.match(re)
  if (!m) throw new Error(`missing hidden ${name}`)
  return m[1]!
}

function jsonResponse(body: unknown, init?: { status?: number }): Response {
  return new Response(JSON.stringify(body), {
    status: init?.status ?? 200,
    headers: { "content-type": "application/json" },
  })
}

describe("oauth authorize flow (happy path)", () => {
  beforeEach(() => {
    vi.restoreAllMocks()
  })

  it("register -> authorize -> login -> consent -> token -> refresh", async () => {
    // Deterministic time for expires_in assertions.
    vi.spyOn(Date, "now").mockReturnValue(1_000_000)

    const app = createApp({
      issuer: "http://localhost:8791",
      tokenEncryptionKeyB64: Buffer.from(new Uint8Array(32).fill(7)).toString("base64"),
      inlineApiBaseUrl: "http://inline.test",
    })

      // Register client.
      const reg = await app.fetch(
        new Request("http://localhost/oauth/register", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ redirect_uris: ["https://example.com/cb"] }),
        }),
      )
      expect(reg.status).toBe(201)
      const { client_id } = await reg.json()

      const verifier = "verifier-123"
      const challenge = await pkceChallenge(verifier)

      // Authorize (GET).
      const authUrl = new URL("http://localhost/oauth/authorize")
      authUrl.searchParams.set("response_type", "code")
      authUrl.searchParams.set("client_id", String(client_id))
      authUrl.searchParams.set("redirect_uri", "https://example.com/cb")
      authUrl.searchParams.set("state", "st")
      authUrl.searchParams.set("scope", "messages:read spaces:read offline_access messages:write")
      authUrl.searchParams.set("code_challenge", challenge)
      authUrl.searchParams.set("code_challenge_method", "S256")

      const authRes = await app.fetch(new Request(authUrl.toString()))
      expect(authRes.status).toBe(200)
      const cookie = extractSetCookieValue(authRes.headers.get("set-cookie"))
      const authHtml = await authRes.text()
      const csrf = extractHidden(authHtml, "csrf")

      // Mock Inline API endpoints.
      const fetchMock = vi.spyOn(globalThis, "fetch" as any).mockImplementation(async (input: any, init?: any) => {
        const u = typeof input === "string" ? input : String(input.url)
        if (u.endsWith("/v1/sendEmailCode")) return jsonResponse({ existingUser: true })
        if (u.endsWith("/v1/verifyEmailCode")) return jsonResponse({ token: "42:tok", userId: 42 })
        if (u.endsWith("/v1/getSpaces")) return jsonResponse({ spaces: [{ id: 1, name: "A" }, { id: 2, name: "B" }], members: [] })
        return jsonResponse({ error: "unexpected" }, { status: 500 })
      })

      // Send email code.
      const sendForm = new FormData()
      sendForm.set("csrf", csrf)
      sendForm.set("email", "a@example.com")
      const sendRes = await app.fetch(
        new Request("http://localhost/oauth/authorize/send-email-code", { method: "POST", headers: { cookie }, body: sendForm }),
      )
      expect(sendRes.status).toBe(200)
      const codeHtml = await sendRes.text()
      expect(codeHtml).toContain("Enter code")

      // Verify code.
      const verifyForm = new FormData()
      verifyForm.set("csrf", csrf)
      verifyForm.set("code", "123456")
      const verifyRes = await app.fetch(
        new Request("http://localhost/oauth/authorize/verify-email-code", { method: "POST", headers: { cookie }, body: verifyForm }),
      )
      expect(verifyRes.status).toBe(200)
      const spacesHtml = await verifyRes.text()
      expect(spacesHtml).toContain("Choose spaces")

      // Consent with a single space.
      const consentForm = new FormData()
      consentForm.set("csrf", csrf)
      consentForm.append("space_id", "1")
      const consentRes = await app.fetch(
        new Request("http://localhost/oauth/authorize/consent", { method: "POST", headers: { cookie }, body: consentForm }),
      )
      expect(consentRes.status).toBe(302)
      const location = consentRes.headers.get("location")
      expect(location).toContain("https://example.com/cb")
      const returned = new URL(location!)
      expect(returned.searchParams.get("state")).toBe("st")
      const code = returned.searchParams.get("code")
      expect(typeof code).toBe("string")

      // Exchange token.
      const tokenForm = new FormData()
      tokenForm.set("grant_type", "authorization_code")
      tokenForm.set("code", String(code))
      tokenForm.set("client_id", String(client_id))
      tokenForm.set("redirect_uri", "https://example.com/cb")
      tokenForm.set("code_verifier", verifier)

      const tokenRes = await app.fetch(new Request("http://localhost/oauth/token", { method: "POST", body: tokenForm }))
      expect(tokenRes.status).toBe(200)
      const tokenJson = await tokenRes.json()
      expect(tokenJson.token_type).toBe("bearer")
      expect(typeof tokenJson.access_token).toBe("string")
      expect(typeof tokenJson.refresh_token).toBe("string")
      expect(tokenJson.expires_in).toBe(3600)

      // Refresh.
      const refreshForm = new FormData()
      refreshForm.set("grant_type", "refresh_token")
      refreshForm.set("refresh_token", tokenJson.refresh_token)
      const refreshRes = await app.fetch(new Request("http://localhost/oauth/token", { method: "POST", body: refreshForm }))
      expect(refreshRes.status).toBe(200)
      const refreshJson = await refreshRes.json()
      expect(refreshJson.refresh_token).not.toBe(tokenJson.refresh_token)

      // Ensure we exercised Inline fetches.
      expect(fetchMock).toHaveBeenCalled()
  })

  it("does not issue refresh token without offline_access", async () => {
    vi.spyOn(Date, "now").mockReturnValue(1_000_000)

    const app = createApp({
      issuer: "http://localhost:8791",
      tokenEncryptionKeyB64: Buffer.from(new Uint8Array(32).fill(7)).toString("base64"),
      inlineApiBaseUrl: "http://inline.test",
    })

    const reg = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ redirect_uris: ["https://example.com/cb"] }),
      }),
    )
    const { client_id } = await reg.json()

    const verifier = "verifier-123"
    const challenge = await pkceChallenge(verifier)

    const authUrl = new URL("http://localhost/oauth/authorize")
    authUrl.searchParams.set("response_type", "code")
    authUrl.searchParams.set("client_id", String(client_id))
    authUrl.searchParams.set("redirect_uri", "https://example.com/cb")
    authUrl.searchParams.set("state", "st")
    authUrl.searchParams.set("scope", "messages:read spaces:read")
    authUrl.searchParams.set("code_challenge", challenge)

    const authRes = await app.fetch(new Request(authUrl.toString()))
    const cookie = extractSetCookieValue(authRes.headers.get("set-cookie"))
    const csrf = extractHidden(await authRes.text(), "csrf")

    vi.spyOn(globalThis, "fetch" as any).mockImplementation(async (input: any) => {
      const u = typeof input === "string" ? input : String(input.url)
      if (u.endsWith("/v1/sendEmailCode")) return jsonResponse({ existingUser: true })
      if (u.endsWith("/v1/verifyEmailCode")) return jsonResponse({ token: "42:tok", userId: 42 })
      if (u.endsWith("/v1/getSpaces")) return jsonResponse({ spaces: [{ id: 1 }], members: [] })
      return jsonResponse({ error: "unexpected" }, { status: 500 })
    })

    const sendForm = new FormData()
    sendForm.set("csrf", csrf)
    sendForm.set("email", "a@example.com")
    await app.fetch(new Request("http://localhost/oauth/authorize/send-email-code", { method: "POST", headers: { cookie }, body: sendForm }))

    const verifyForm = new FormData()
    verifyForm.set("csrf", csrf)
    verifyForm.set("code", "123456")
    await app.fetch(new Request("http://localhost/oauth/authorize/verify-email-code", { method: "POST", headers: { cookie }, body: verifyForm }))

    const consentForm = new FormData()
    consentForm.set("csrf", csrf)
    consentForm.append("space_id", "1")
    const consentRes = await app.fetch(new Request("http://localhost/oauth/authorize/consent", { method: "POST", headers: { cookie }, body: consentForm }))
    const code = new URL(consentRes.headers.get("location")!).searchParams.get("code")

    const tokenForm = new FormData()
    tokenForm.set("grant_type", "authorization_code")
    tokenForm.set("code", String(code))
    tokenForm.set("client_id", String(client_id))
    tokenForm.set("redirect_uri", "https://example.com/cb")
    tokenForm.set("code_verifier", verifier)

    const tokenRes = await app.fetch(new Request("http://localhost/oauth/token", { method: "POST", body: tokenForm }))
    const tokenJson = await tokenRes.json()
    expect(tokenJson.refresh_token).toBeUndefined()
  })
})
