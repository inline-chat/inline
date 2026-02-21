import { afterEach, describe, expect, it, vi } from "vitest"
import { createApp } from "./app"

describe("mcp app", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("createApp works without options", async () => {
    const app = createApp()
    const res = await app.fetch(new Request("https://mcp.inline.chat/health"))
    expect(res.status).toBe(200)
  })

  it("health returns ok", async () => {
    const app = createApp({ issuer: "http://localhost:1234" })
    const res = await app.fetch(new Request("http://localhost/health"))
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ ok: true })
  })

  it("root returns a description", async () => {
    const app = createApp({ issuer: "http://localhost:1234" })
    const res = await app.fetch(new Request("http://localhost/"))
    expect(res.status).toBe(200)
    expect(res.headers.get("content-type")).toContain("text/plain")
    expect(await res.text()).toContain("Inline MCP server")
  })

  it("well-known protected resource points at configured oauth issuer", async () => {
    const app = createApp({ issuer: "https://mcp.inline.chat", oauthIssuer: "https://api.inline.chat" })
    const res = await app.fetch(new Request("https://mcp.inline.chat/.well-known/oauth-protected-resource"))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.resource).toBe("https://mcp.inline.chat")
    expect(body.authorization_servers).toEqual(["https://api.inline.chat"])
  })

  it("proxies oauth routes to upstream server", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ issuer: "https://api.inline.chat" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    )

    const app = createApp({
      issuer: "https://mcp.inline.chat",
      oauthProxyBaseUrl: "https://api.inline.chat",
    })

    const res = await app.fetch(new Request("https://mcp.inline.chat/.well-known/oauth-authorization-server"))
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ issuer: "https://api.inline.chat" })

    expect(fetchMock).toHaveBeenCalled()
    const [url] = fetchMock.mock.calls[0] ?? []
    expect(String(url)).toBe("https://api.inline.chat/.well-known/oauth-authorization-server")
  })

  it("returns 502 when oauth upstream is unavailable", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("boom"))

    const app = createApp({
      issuer: "https://mcp.inline.chat",
      oauthProxyBaseUrl: "https://api.inline.chat",
    })

    const res = await app.fetch(new Request("https://mcp.inline.chat/oauth/register", { method: "POST" }))
    expect(res.status).toBe(502)
    expect(await res.json()).toEqual({ error: "oauth_upstream_unavailable" })
  })

  it("rate limits mcp initialization requests", async () => {
    const app = createApp({
      issuer: "http://localhost:1234",
      endpointRateLimits: {
        mcpInitialize: { max: 1, windowMs: 60_000 },
      },
    })

    const first = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: { "x-forwarded-for": "10.0.0.1" },
      }),
    )
    expect(first.status).toBe(401)

    const second = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: { "x-forwarded-for": "10.0.0.1" },
      }),
    )
    expect(second.status).toBe(429)
    expect(second.headers.get("retry-after")).toBeTruthy()
  })

  it("rejects requests from disallowed hosts", async () => {
    const app = createApp({
      allowedHosts: ["allowed.example"],
      allowedOriginHosts: ["allowed.example"],
    })
    const res = await app.fetch(new Request("http://localhost/health"))
    expect(res.status).toBe(403)
    expect(await res.json()).toEqual({ error: "forbidden_host" })
  })

  it("rejects requests from disallowed origins", async () => {
    const app = createApp({
      allowedHosts: ["localhost"],
      allowedOriginHosts: ["good.example"],
    })
    const res = await app.fetch(
      new Request("http://localhost/health", {
        headers: { origin: "https://evil.example" },
      }),
    )
    expect(res.status).toBe(403)
    expect(await res.json()).toEqual({ error: "forbidden_origin" })
  })

  it("handles OPTIONS preflight for allowed origins", async () => {
    const app = createApp({
      allowedHosts: ["localhost"],
      allowedOriginHosts: ["good.example"],
    })
    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "OPTIONS",
        headers: {
          origin: "https://good.example",
          "access-control-request-method": "POST",
          "access-control-request-headers": "authorization, content-type, accept, mcp-session-id",
        },
      }),
    )

    expect(res.status).toBe(204)
    expect(res.headers.get("access-control-allow-origin")).toBe("https://good.example")
    expect(res.headers.get("access-control-allow-methods")).toContain("POST")
    expect(res.headers.get("access-control-allow-methods")).toContain("DELETE")
    const allowHeaders = res.headers.get("access-control-allow-headers") ?? ""
    expect(allowHeaders).toContain("authorization")
    expect(allowHeaders).toContain("content-type")
    expect(allowHeaders).toContain("accept")
    expect(allowHeaders).toContain("mcp-session-id")
  })

  it("rejects OPTIONS preflight from disallowed origins", async () => {
    const app = createApp({
      allowedHosts: ["localhost"],
      allowedOriginHosts: ["good.example"],
    })
    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "OPTIONS",
        headers: {
          origin: "https://evil.example",
          "access-control-request-method": "POST",
          "access-control-request-headers": "authorization",
        },
      }),
    )

    expect(res.status).toBe(403)
    expect(await res.json()).toEqual({ error: "forbidden_origin" })
    expect(res.headers.get("access-control-allow-origin")).toBeNull()
  })

  it("adds CORS expose headers to actual responses for allowed origins", async () => {
    const app = createApp({
      allowedHosts: ["localhost"],
      allowedOriginHosts: ["good.example"],
    })
    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: { origin: "https://good.example" },
      }),
    )

    expect(res.status).toBe(401)
    expect(res.headers.get("access-control-allow-origin")).toBe("https://good.example")
    const exposeHeaders = res.headers.get("access-control-expose-headers") ?? ""
    expect(exposeHeaders).toContain("mcp-session-id")
    expect(exposeHeaders).toContain("www-authenticate")
    expect(res.headers.get("www-authenticate")).toContain("Bearer")
  })

  it("unknown route 404s", async () => {
    const app = createApp({ issuer: "http://localhost:1234" })
    const res = await app.fetch(new Request("http://localhost/nope"))
    expect(res.status).toBe(404)
  })
})
