import { describe, expect, it } from "vitest"
import { createApp } from "./app"
import type { Store } from "./store"

describe("mcp app", () => {
  it("createApp works without options", async () => {
    const app = createApp()
    const res = await app.fetch(new Request("http://localhost/health"))
    expect(res.status).toBe(200)
  })

  it("health returns ok", async () => {
    const app = createApp({ issuer: "http://localhost:1234", dbPath: ":memory:" })
    const res = await app.fetch(new Request("http://localhost/health"))
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ ok: true })
  })

  it("root returns a description", async () => {
    const app = createApp({ issuer: "http://localhost:1234", dbPath: ":memory:" })
    const res = await app.fetch(new Request("http://localhost/"))
    expect(res.status).toBe(200)
    expect(res.headers.get("content-type")).toContain("text/plain")
    expect(await res.text()).toContain("Inline MCP server")
  })

  it("well-known oauth metadata uses issuer", async () => {
    const app = createApp({ issuer: "https://mcp.inline.chat", dbPath: ":memory:" })
    const res = await app.fetch(new Request("http://localhost/.well-known/oauth-authorization-server"))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.issuer).toBe("https://mcp.inline.chat")
    expect(body.authorization_endpoint).toBe("https://mcp.inline.chat/oauth/authorize")
    expect(body.token_endpoint).toBe("https://mcp.inline.chat/oauth/token")
    expect(body.registration_endpoint).toBe("https://mcp.inline.chat/oauth/register")
    expect(body.code_challenge_methods_supported).toEqual(["S256"])
  })

  it("well-known protected resource points at issuer", async () => {
    const app = createApp({ issuer: "https://mcp.inline.chat", dbPath: ":memory:" })
    const res = await app.fetch(new Request("http://localhost/.well-known/oauth-protected-resource"))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.resource).toBe("https://mcp.inline.chat")
    expect(body.authorization_servers).toEqual(["https://mcp.inline.chat"])
  })

  it("oauth placeholder endpoints exist", async () => {
    const app = createApp({ issuer: "http://localhost:1234", dbPath: ":memory:" })
    const res = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ redirect_uris: ["https://example.com/cb"], client_name: "x" }),
      }),
    )
    expect(res.status).toBe(201)
    const body = await res.json()
    expect(typeof body.client_id).toBe("string")
    expect(body.redirect_uris).toEqual(["https://example.com/cb"])
  })

  it("oauth placeholder endpoints reject other methods", async () => {
    const app = createApp({ issuer: "http://localhost:1234", dbPath: ":memory:" })
    const res = await app.fetch(new Request("http://localhost/oauth/token", { method: "PUT" }))
    expect(res.status).toBe(404)
  })

  it("oauth authorize and token placeholders return 501", async () => {
    const app = createApp({ issuer: "http://localhost:1234", dbPath: ":memory:" })
    const a = await app.fetch(new Request("http://localhost/oauth/authorize"))
    expect(a.status).toBe(400)

    const t = await app.fetch(new Request("http://localhost/oauth/token", { method: "POST" }))
    expect(t.status).toBe(400)
  })

  it("oauth authorize placeholder rejects invalid methods", async () => {
    const app = createApp({ issuer: "http://localhost:1234", dbPath: ":memory:" })
    const res = await app.fetch(new Request("http://localhost/oauth/authorize", { method: "PUT" }))
    expect(res.status).toBe(404)
  })

  it("defaults issuer from env", async () => {
    const prev = process.env.MCP_ISSUER
    process.env.MCP_ISSUER = "http://env-issuer.test"
    try {
      const app = createApp({ dbPath: ":memory:" })
      const res = await app.fetch(new Request("http://localhost/.well-known/oauth-authorization-server"))
      const body = await res.json()
      expect(body.issuer).toBe("http://env-issuer.test")
    } finally {
      if (prev == null) delete process.env.MCP_ISSUER
      else process.env.MCP_ISSUER = prev
    }
  })

  it("falls back to localhost issuer when env missing", async () => {
    const prev = process.env.MCP_ISSUER
    delete process.env.MCP_ISSUER
    try {
      const app = createApp({ dbPath: ":memory:" })
      const res = await app.fetch(new Request("http://localhost/.well-known/oauth-authorization-server"))
      const body = await res.json()
      expect(body.issuer).toBe("http://localhost:8791")
    } finally {
      if (prev != null) process.env.MCP_ISSUER = prev
    }
  })

  it("unknown route 404s", async () => {
    const app = createApp({ issuer: "http://localhost:1234", dbPath: ":memory:" })
    const res = await app.fetch(new Request("http://localhost/nope"))
    expect(res.status).toBe(404)
  })

  it("uses injected store", async () => {
    let cleanupCalled = 0
    const store: Store = {
      ensureSchema() {},
      cleanupExpired() {
        cleanupCalled++
      },
      createClient() {
        throw new Error("not used")
      },
      getClient() {
        return null
      },
      createAuthRequest() {
        throw new Error("not used")
      },
      getAuthRequest() {
        return null
      },
      setAuthRequestEmail() {},
      setAuthRequestInlineTokenEnc() {},
      setAuthRequestInlineUserId() {},
      deleteAuthRequest() {},
      createGrant() {
        throw new Error("not used")
      },
      getGrant() {
        return null
      },
      createAuthCode() {
        throw new Error("not used")
      },
      getAuthCode() {
        return null
      },
      markAuthCodeUsed() {},
      createAccessToken() {},
      getAccessToken() {
        return null
      },
      createRefreshToken() {},
      getRefreshToken() {
        return null
      },
      revokeRefreshToken() {},
    }

    const app = createApp({ issuer: "http://localhost:1234", store })
    const res = await app.fetch(new Request("http://localhost/.well-known/oauth-protected-resource"))
    expect(res.status).toBe(200)
    expect(cleanupCalled).toBe(1)
  })
})
