import { afterEach, describe, expect, it, vi } from "vitest"
import { createApp } from "../app"

function createProxyApp() {
  return createApp({
    issuer: "http://localhost:8791",
    oauthProxyBaseUrl: "https://api.inline.chat",
    allowedHosts: ["localhost"],
    allowedOriginHosts: ["localhost"],
  })
}

describe("oauth authorize proxy", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("redirects authorize GET to the canonical issuer origin", async () => {
    const app = createProxyApp()
    const res = await app.fetch(
      new Request(
        "http://localhost/oauth/authorize?response_type=code&client_id=c1&redirect_uri=https://example.com/callback&state=s&code_challenge=abc",
      ),
    )

    expect(res.status).toBe(307)
    expect(res.headers.get("location")).toBe(
      "https://api.inline.chat/oauth/authorize?response_type=code&client_id=c1&redirect_uri=https://example.com/callback&state=s&code_challenge=abc",
    )
    expect(res.headers.get("cache-control")).toBe("no-store")
  })

  it("forwards authorize form posts", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("<html>verify</html>", { status: 200 }))

    const app = createProxyApp()
    const form = new FormData()
    form.set("csrf", "csrf-token")
    form.set("email", "a@example.com")

    const res = await app.fetch(
      new Request("http://localhost/oauth/authorize/send-email-code", {
        method: "POST",
        body: form,
      }),
    )

    expect(res.status).toBe(200)
    expect(await res.text()).toContain("verify")

    const [url, init] = fetchMock.mock.calls.at(-1) ?? []
    expect(String(url)).toBe("https://api.inline.chat/oauth/authorize/send-email-code")
    expect((init as RequestInit).method).toBe("POST")
  })

  it("forwards token and revoke aliases", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("{}", { status: 200 }))

    const app = createProxyApp()

    await app.fetch(new Request("http://localhost/token", { method: "POST" }))
    await app.fetch(new Request("http://localhost/revoke", { method: "POST" }))

    const urls = fetchMock.mock.calls.map((call) => String(call[0]))
    expect(urls).toContain("https://api.inline.chat/token")
    expect(urls).toContain("https://api.inline.chat/revoke")
  })
})
