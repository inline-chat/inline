import { describe, expect, it, vi } from "vitest"
import { createApp } from "../app"
import { createMemoryStore } from "../store"

function jsonResponse(body: unknown, init?: { status?: number }): Response {
  return new Response(JSON.stringify(body), {
    status: init?.status ?? 200,
    headers: { "content-type": "application/json" },
  })
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

describe("oauth error cases", () => {
  it("authorize validates request params and client/redirect", async () => {
    const store = createMemoryStore()
    const app = createApp({ store })

    const invalidResponseType = await app.fetch(
      new Request("http://localhost/oauth/authorize?response_type=token&client_id=x&redirect_uri=https://e/cb&state=s&code_challenge=c"),
    )
    expect(invalidResponseType.status).toBe(400)

    const reg = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ redirect_uris: ["https://example.com/cb"] }),
      }),
    )
    const { client_id } = await reg.json()

    const missingParams = await app.fetch(new Request(`http://localhost/oauth/authorize?response_type=code&client_id=${client_id}`))
    expect(missingParams.status).toBe(400)

    const badMethod = await app.fetch(new Request("http://localhost/oauth/authorize", { method: "POST" }))
    expect(badMethod.status).toBe(404)

    const invalidChallengeMethod = await app.fetch(
      new Request(
        `http://localhost/oauth/authorize?response_type=code&client_id=${client_id}&redirect_uri=https://example.com/cb&state=s&code_challenge=c&code_challenge_method=plain`,
      ),
    )
    expect(invalidChallengeMethod.status).toBe(400)

    const invalidClient = await app.fetch(
      new Request(
        `http://localhost/oauth/authorize?response_type=code&client_id=missing&redirect_uri=https://example.com/cb&state=s&code_challenge=c`,
      ),
    )
    expect(invalidClient.status).toBe(400)

    const invalidRedirect = await app.fetch(
      new Request(
        `http://localhost/oauth/authorize?response_type=code&client_id=${client_id}&redirect_uri=https://evil.example/cb&state=s&code_challenge=c`,
      ),
    )
    expect(invalidRedirect.status).toBe(400)
  })

  it("send-email-code validates csrf and email and handles inline failures", async () => {
    const store = createMemoryStore()
    const app = createApp({ store, inlineApiBaseUrl: "http://inline.test" })

    const reg = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ redirect_uris: ["https://example.com/cb"] }),
      }),
    )
    const { client_id } = await reg.json()

    const authUrl = new URL("http://localhost/oauth/authorize")
    authUrl.searchParams.set("response_type", "code")
    authUrl.searchParams.set("client_id", String(client_id))
    authUrl.searchParams.set("redirect_uri", "https://example.com/cb")
    authUrl.searchParams.set("state", "st")
    authUrl.searchParams.set("code_challenge", "cc")
    authUrl.searchParams.set("code_challenge_method", "S256")

    const authRes = await app.fetch(new Request(authUrl.toString()))
    const cookie = extractSetCookieValue(authRes.headers.get("set-cookie"))
    const csrf = extractHidden(await authRes.text(), "csrf")

    const badCsrfForm = new FormData()
    badCsrfForm.set("csrf", "nope")
    badCsrfForm.set("email", "a@example.com")
    const badCsrf = await app.fetch(
      new Request("http://localhost/oauth/authorize/send-email-code", { method: "POST", headers: { cookie }, body: badCsrfForm }),
    )
    expect(badCsrf.status).toBe(400)

    const badEmailForm = new FormData()
    badEmailForm.set("csrf", csrf)
    badEmailForm.set("email", "not-an-email")
    const badEmail = await app.fetch(
      new Request("http://localhost/oauth/authorize/send-email-code", { method: "POST", headers: { cookie }, body: badEmailForm }),
    )
    expect(badEmail.status).toBe(400)

    vi.spyOn(globalThis, "fetch" as any).mockImplementation(async (input: any) => {
      const u = typeof input === "string" ? input : String(input.url)
      if (u.endsWith("/v1/sendEmailCode")) return jsonResponse({ error: "nope" }, { status: 500 })
      return jsonResponse({ error: "unexpected" }, { status: 500 })
    })

    const okForm = new FormData()
    okForm.set("csrf", csrf)
    okForm.set("email", "a@example.com")
    const inlineFail = await app.fetch(
      new Request("http://localhost/oauth/authorize/send-email-code", { method: "POST", headers: { cookie }, body: okForm }),
    )
    expect(inlineFail.status).toBe(502)
  })

  it("verify-email-code handles missing email, inline failures, and encryption misconfig", async () => {
    const store = createMemoryStore()
    const app = createApp({ store, inlineApiBaseUrl: "http://inline.test" })

    const reg = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ redirect_uris: ["https://example.com/cb"] }),
      }),
    )
    const { client_id } = await reg.json()

    const authUrl = new URL("http://localhost/oauth/authorize")
    authUrl.searchParams.set("response_type", "code")
    authUrl.searchParams.set("client_id", String(client_id))
    authUrl.searchParams.set("redirect_uri", "https://example.com/cb")
    authUrl.searchParams.set("state", "st")
    authUrl.searchParams.set("code_challenge", "cc")
    const authRes = await app.fetch(new Request(authUrl.toString()))
    const cookie = extractSetCookieValue(authRes.headers.get("set-cookie"))
    const csrf = extractHidden(await authRes.text(), "csrf")

    // Missing email (never sent code).
    const verifyForm = new FormData()
    verifyForm.set("csrf", csrf)
    verifyForm.set("code", "123456")
    const missingEmail = await app.fetch(
      new Request("http://localhost/oauth/authorize/verify-email-code", { method: "POST", headers: { cookie }, body: verifyForm }),
    )
    expect(missingEmail.status).toBe(400)

    // Now set email via send-email-code success.
    vi.spyOn(globalThis, "fetch" as any).mockImplementation(async (input: any) => {
      const u = typeof input === "string" ? input : String(input.url)
      if (u.endsWith("/v1/sendEmailCode")) return jsonResponse({ existingUser: true })
      if (u.endsWith("/v1/verifyEmailCode")) return jsonResponse({ error: "nope" }, { status: 401 })
      return jsonResponse({ error: "unexpected" }, { status: 500 })
    })

    const sendForm = new FormData()
    sendForm.set("csrf", csrf)
    sendForm.set("email", "a@example.com")
    const sendRes = await app.fetch(
      new Request("http://localhost/oauth/authorize/send-email-code", { method: "POST", headers: { cookie }, body: sendForm }),
    )
    expect(sendRes.status).toBe(200)

    const verifyFail = await app.fetch(
      new Request("http://localhost/oauth/authorize/verify-email-code", { method: "POST", headers: { cookie }, body: verifyForm }),
    )
    expect(verifyFail.status).toBe(401)

    // Invalid CSRF.
    vi.spyOn(globalThis, "fetch" as any).mockImplementation(async (input: any) => {
      const u = typeof input === "string" ? input : String(input.url)
      if (u.endsWith("/v1/sendEmailCode")) return jsonResponse({ existingUser: true })
      if (u.endsWith("/v1/verifyEmailCode")) return jsonResponse({ token: "42:tok", userId: 42 })
      if (u.endsWith("/v1/getSpaces")) return jsonResponse({ spaces: [{ id: 1 }], members: [] })
      return jsonResponse({ error: "unexpected" }, { status: 500 })
    })

    const badCsrfVerify = new FormData()
    badCsrfVerify.set("csrf", "nope")
    badCsrfVerify.set("code", "123456")
    const badCsrfRes = await app.fetch(
      new Request("http://localhost/oauth/authorize/verify-email-code", { method: "POST", headers: { cookie }, body: badCsrfVerify }),
    )
    expect(badCsrfRes.status).toBe(400)

    const badCodeVerify = new FormData()
    badCodeVerify.set("csrf", csrf)
    badCodeVerify.set("code", "1")
    const badCodeRes = await app.fetch(
      new Request("http://localhost/oauth/authorize/verify-email-code", { method: "POST", headers: { cookie }, body: badCodeVerify }),
    )
    expect(badCodeRes.status).toBe(400)

    // Encryption misconfig branch: verify succeeds but key missing.
    vi.spyOn(globalThis, "fetch" as any).mockImplementation(async (input: any) => {
      const u = typeof input === "string" ? input : String(input.url)
      if (u.endsWith("/v1/sendEmailCode")) return jsonResponse({ existingUser: true })
      if (u.endsWith("/v1/verifyEmailCode")) return jsonResponse({ token: "42:tok", userId: 42 })
      if (u.endsWith("/v1/getSpaces")) return jsonResponse({ spaces: [{ id: 1 }], members: [] })
      return jsonResponse({ error: "unexpected" }, { status: 500 })
    })

    const misconfig = await app.fetch(
      new Request("http://localhost/oauth/authorize/verify-email-code", { method: "POST", headers: { cookie }, body: verifyForm }),
    )
    expect(misconfig.status).toBe(500)
  })

  it("consent validates csrf, selection, decrypt, and selection subset", async () => {
    const store = createMemoryStore()
    const app = createApp({
      store,
      issuer: "http://localhost:8791",
      tokenEncryptionKeyB64: Buffer.from(new Uint8Array(32).fill(9)).toString("base64"),
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

    const authUrl = new URL("http://localhost/oauth/authorize")
    authUrl.searchParams.set("response_type", "code")
    authUrl.searchParams.set("client_id", String(client_id))
    authUrl.searchParams.set("redirect_uri", "https://example.com/cb")
    authUrl.searchParams.set("state", "st")
    authUrl.searchParams.set("code_challenge", "cc")
    const authRes = await app.fetch(new Request(authUrl.toString()))
    const cookie = extractSetCookieValue(authRes.headers.get("set-cookie"))
    const csrf = extractHidden(await authRes.text(), "csrf")

    vi.spyOn(globalThis, "fetch" as any).mockImplementation(async (input: any) => {
      const u = typeof input === "string" ? input : String(input.url)
      if (u.endsWith("/v1/sendEmailCode")) return jsonResponse({ existingUser: true })
      if (u.endsWith("/v1/verifyEmailCode")) return jsonResponse({ token: "42:tok", userId: 42 })
      if (u.endsWith("/v1/getSpaces")) return jsonResponse({ spaces: [{ id: 1 }, { id: 2 }], members: [] })
      return jsonResponse({ error: "unexpected" }, { status: 500 })
    })

    const sendForm = new FormData()
    sendForm.set("csrf", csrf)
    sendForm.set("email", "a@example.com")
    await app.fetch(new Request("http://localhost/oauth/authorize/send-email-code", { method: "POST", headers: { cookie }, body: sendForm }))

    const verifyForm = new FormData()
    verifyForm.set("csrf", csrf)
    verifyForm.set("code", "123456")
    const verifyRes = await app.fetch(
      new Request("http://localhost/oauth/authorize/verify-email-code", { method: "POST", headers: { cookie }, body: verifyForm }),
    )
    expect(verifyRes.status).toBe(200)

    const badCsrf = new FormData()
    badCsrf.set("csrf", "nope")
    badCsrf.append("space_id", "1")
    const badCsrfRes = await app.fetch(
      new Request("http://localhost/oauth/authorize/consent", { method: "POST", headers: { cookie }, body: badCsrf }),
    )
    expect(badCsrfRes.status).toBe(400)

    const noSelection = new FormData()
    noSelection.set("csrf", csrf)
    const noSelectionRes = await app.fetch(
      new Request("http://localhost/oauth/authorize/consent", { method: "POST", headers: { cookie }, body: noSelection }),
    )
    expect(noSelectionRes.status).toBe(400)

    const badSelection = new FormData()
    badSelection.set("csrf", csrf)
    badSelection.append("space_id", "999")
    const badSelectionRes = await app.fetch(
      new Request("http://localhost/oauth/authorize/consent", { method: "POST", headers: { cookie }, body: badSelection }),
    )
    expect(badSelectionRes.status).toBe(400)

    // Corrupt session (decrypt fails): override auth_request token.
    const arId = cookie.split("=", 2)[1]!
    store.setAuthRequestInlineTokenEnc(arId, "bad")
    store.setAuthRequestInlineUserId(arId, 42n)

    const decryptFail = new FormData()
    decryptFail.set("csrf", csrf)
    decryptFail.append("space_id", "1")
    const decryptFailRes = await app.fetch(
      new Request("http://localhost/oauth/authorize/consent", { method: "POST", headers: { cookie }, body: decryptFail }),
    )
    expect(decryptFailRes.status).toBe(400)
  })

  it("token endpoint: json parsing, unsupported grant, and invalid_grant", async () => {
    const app = createApp()

    const invalidJson = await app.fetch(
      new Request("http://localhost/oauth/token", { method: "POST", headers: { "content-type": "application/json" }, body: "{" }),
    )
    expect(invalidJson.status).toBe(400)

    const nonObject = await app.fetch(
      new Request("http://localhost/oauth/token", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify("nope"),
      }),
    )
    expect(nonObject.status).toBe(400)

    const unsupported = await app.fetch(
      new Request("http://localhost/oauth/token", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ grant_type: "password" }),
      }),
    )
    expect(unsupported.status).toBe(400)

    const missingRefresh = await app.fetch(
      new Request("http://localhost/oauth/token", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ grant_type: "refresh_token" }),
      }),
    )
    expect(missingRefresh.status).toBe(400)

    const invalidGrant = await app.fetch(
      new Request("http://localhost/oauth/token", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          grant_type: "authorization_code",
          code: "missing",
          client_id: "c",
          redirect_uri: "https://example.com/cb",
          code_verifier: "v",
        }),
      }),
    )
    expect(invalidGrant.status).toBe(400)
  })
})
