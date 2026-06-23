import { afterEach, describe, expect, it, vi } from "vitest"
import { createApp } from "../app"

describe("oauth proxy error cases", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("returns protected resource metadata locally", async () => {
    const app = createApp({
      issuer: "https://mcp.inline.chat",
      oauthIssuer: "https://api.inline.chat",
    })

    const res = await app.fetch(new Request("https://mcp.inline.chat/.well-known/oauth-protected-resource"))
    expect(res.status).toBe(200)

    const body = await res.json()
    expect(body.resource).toBe("https://mcp.inline.chat")
    expect(body.authorization_servers).toEqual(["https://api.inline.chat"])
    expect(body.bearer_methods_supported).toEqual(["header"])
  })

  it("returns 502 when oauth upstream throws", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("upstream down"))

    const app = createApp({
      issuer: "http://localhost:8791",
      oauthProxyBaseUrl: "https://api.inline.chat",
      allowedHosts: ["localhost"],
      allowedOriginHosts: ["localhost"],
    })

    const res = await app.fetch(new Request("http://localhost/oauth/token", { method: "POST" }))
    expect(res.status).toBe(502)
    expect(await res.json()).toEqual({ error: "oauth_upstream_unavailable" })
  })

  it("passes through oauth upstream status/body", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ error: "invalid_grant" }), {
        status: 400,
        headers: { "content-type": "application/json" },
      }),
    )

    const app = createApp({
      issuer: "http://localhost:8791",
      oauthProxyBaseUrl: "https://api.inline.chat",
      allowedHosts: ["localhost"],
      allowedOriginHosts: ["localhost"],
    })

    const res = await app.fetch(new Request("http://localhost/oauth/token", { method: "POST" }))
    expect(res.status).toBe(400)
    expect(await res.json()).toEqual({ error: "invalid_grant" })
  })
})
