import { afterEach, describe, expect, it, vi } from "vitest"
import { createApp } from "../app"

const initRequest = {
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: {
    protocolVersion: "2025-11-25",
    capabilities: {},
    clientInfo: { name: "vitest", version: "0.0.0" },
  },
}

function activeIntrospection(input: {
  grantId: string
  clientId?: string
  inlineUserId?: string
  scope?: string
  spaceIds?: string[]
  allowDms?: boolean
  allowHomeThreads?: boolean
  inlineToken?: string
}): Record<string, unknown> {
  return {
    active: true,
    grant_id: input.grantId,
    client_id: input.clientId ?? "client-1",
    scope: input.scope ?? "messages:read spaces:read messages:write",
    exp: Math.floor(Date.now() / 1000) + 3600,
    inline_user_id: input.inlineUserId ?? "1",
    space_ids: input.spaceIds ?? ["10"],
    allow_dms: input.allowDms ?? false,
    allow_home_threads: input.allowHomeThreads ?? false,
    inline_token: input.inlineToken ?? "1:inline-token",
  }
}

describe("/mcp", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("requires Authorization", async () => {
    const app = createApp({ issuer: "http://localhost:8791" })
    const res = await app.fetch(new Request("http://localhost/mcp", { method: "POST" }))
    expect(res.status).toBe(401)
    expect(res.headers.get("www-authenticate")).toContain("Bearer")
  })

  it("rejects invalid authorization header format", async () => {
    const app = createApp({ issuer: "http://localhost:8791" })
    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: { authorization: "Token xyz" },
      }),
    )
    expect(res.status).toBe(401)
    expect(await res.json()).toEqual({ error: "invalid_authorization" })
  })

  it("rejects invalid access tokens from introspection", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({ active: false }), { status: 401 }))

    const app = createApp({
      issuer: "http://localhost:8791",
      oauthIntrospectionUrl: "https://api.inline.chat/oauth/introspect",
      oauthInternalSharedSecret: "secret",
    })

    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: { authorization: "Bearer mcp_at_nope" },
      }),
    )
    expect(res.status).toBe(401)
  })

  it("returns 502 when introspection upstream is unavailable", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("network down"))

    const app = createApp({
      issuer: "http://localhost:8791",
      oauthIntrospectionUrl: "https://api.inline.chat/oauth/introspect",
      oauthInternalSharedSecret: "secret",
    })

    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: { authorization: "Bearer mcp_at_nope" },
      }),
    )

    expect(res.status).toBe(502)
    expect(await res.json()).toEqual({ error: "oauth_introspection_unavailable" })
  })

  it("returns 502 when introspection upstream responds non-200", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({ error: "boom" }), { status: 500 }))

    const app = createApp({
      issuer: "http://localhost:8791",
      oauthIntrospectionUrl: "https://api.inline.chat/oauth/introspect",
      oauthInternalSharedSecret: "secret",
    })

    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: { authorization: "Bearer mcp_at_nope" },
      }),
    )

    expect(res.status).toBe(502)
    expect(await res.json()).toEqual({ error: "oauth_introspection_failed" })
  })

  it("returns 502 when introspection response is invalid json", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("not-json", { status: 200 }))

    const app = createApp({
      issuer: "http://localhost:8791",
      oauthIntrospectionUrl: "https://api.inline.chat/oauth/introspect",
      oauthInternalSharedSecret: "secret",
    })

    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: { authorization: "Bearer mcp_at_nope" },
      }),
    )

    expect(res.status).toBe(502)
    expect(await res.json()).toEqual({ error: "oauth_introspection_invalid_response" })
  })

  it("returns 502 when introspection user id cannot be parsed as bigint", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          activeIntrospection({
            grantId: "g1",
            inlineUserId: "not-a-number",
          }),
        ),
        { status: 200 },
      ),
    )

    const app = createApp({
      issuer: "http://localhost:8791",
      oauthIntrospectionUrl: "https://api.inline.chat/oauth/introspect",
      oauthInternalSharedSecret: "secret",
    })

    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: { authorization: "Bearer mcp_at_nope" },
      }),
    )

    expect(res.status).toBe(502)
    expect(await res.json()).toEqual({ error: "oauth_introspection_invalid_user" })
  })

  it("treats malformed active introspection payload as invalid token", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          active: true,
          grant_id: "g1",
          client_id: "c1",
          scope: "messages:read",
          exp: Math.floor(Date.now() / 1000) + 3600,
          inline_user_id: "1",
          space_ids: ["10"],
          allow_dms: true,
          allow_home_threads: true,
          // missing inline_token
        }),
        { status: 200 },
      ),
    )

    const app = createApp({
      issuer: "http://localhost:8791",
      oauthIntrospectionUrl: "https://api.inline.chat/oauth/introspect",
      oauthInternalSharedSecret: "secret",
    })

    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: { authorization: "Bearer mcp_at_nope" },
      }),
    )

    expect(res.status).toBe(401)
    expect(await res.json()).toEqual({ error: "invalid_token" })
  })

  it("returns 500 when oauth secret is missing", async () => {
    const app = createApp({
      issuer: "http://localhost:8791",
      oauthIntrospectionUrl: "https://api.inline.chat/oauth/introspect",
      oauthInternalSharedSecret: null,
    })

    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: { authorization: "Bearer token" },
      }),
    )
    expect(res.status).toBe(500)
    expect(await res.json()).toEqual({ error: "mcp_oauth_not_configured" })
  })

  it("rejects requests with unknown session id", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify(activeIntrospection({ grantId: "g1" })), { status: 200 }))

    const app = createApp({
      issuer: "http://localhost:8791",
      oauthIntrospectionUrl: "https://api.inline.chat/oauth/introspect",
      oauthInternalSharedSecret: "secret",
    })

    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "GET",
        headers: { authorization: "Bearer mcp_at_ok", accept: "text/event-stream", "mcp-session-id": "missing" },
      }),
    )
    expect(res.status).toBe(404)
  })

  it("initializes a streamable session for valid token", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify(activeIntrospection({ grantId: "g1" })), { status: 200 }))

    const app = createApp({
      issuer: "http://localhost:8791",
      oauthIntrospectionUrl: "https://api.inline.chat/oauth/introspect",
      oauthInternalSharedSecret: "secret",
    })

    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: {
          authorization: "Bearer mcp_at_valid",
          accept: "application/json, text/event-stream",
          "content-type": "application/json",
        },
        body: JSON.stringify(initRequest),
      }),
    )

    expect(res.status).toBe(200)
    expect(res.headers.get("content-type")).toContain("text/event-stream")
    expect(res.headers.get("mcp-session-id")).toBeTruthy()
  })

  it("rejects session grant mismatches", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockImplementation(async (_input: unknown, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body ?? "{}")) as { token?: string }
      if (body.token === "token-1") {
        return new Response(JSON.stringify(activeIntrospection({ grantId: "g1", inlineUserId: "1", inlineToken: "1:t1" })), {
          status: 200,
        })
      }
      if (body.token === "token-2") {
        return new Response(JSON.stringify(activeIntrospection({ grantId: "g2", inlineUserId: "2", inlineToken: "2:t2" })), {
          status: 200,
        })
      }
      return new Response(JSON.stringify({ active: false }), { status: 401 })
    })

    const app = createApp({
      issuer: "http://localhost:8791",
      oauthIntrospectionUrl: "https://api.inline.chat/oauth/introspect",
      oauthInternalSharedSecret: "secret",
    })

    const initRes = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: {
          authorization: "Bearer token-1",
          accept: "application/json, text/event-stream",
          "content-type": "application/json",
        },
        body: JSON.stringify(initRequest),
      }),
    )

    expect(initRes.status).toBe(200)
    const sessionId = initRes.headers.get("mcp-session-id")
    expect(sessionId).toBeTruthy()

    const mismatch = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "GET",
        headers: {
          authorization: "Bearer token-2",
          accept: "text/event-stream",
          "mcp-session-id": sessionId!,
        },
      }),
    )

    expect(mismatch.status).toBe(403)
    expect(fetchMock).toHaveBeenCalled()
  })

  it("accepts existing session requests for the same grant", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => {
      return new Response(JSON.stringify(activeIntrospection({ grantId: "g1", inlineUserId: "1", inlineToken: "1:t1" })), {
        status: 200,
      })
    })

    const app = createApp({
      issuer: "http://localhost:8791",
      oauthIntrospectionUrl: "https://api.inline.chat/oauth/introspect",
      oauthInternalSharedSecret: "secret",
    })

    const initRes = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: {
          authorization: "Bearer token-1",
          accept: "application/json, text/event-stream",
          "content-type": "application/json",
        },
        body: JSON.stringify(initRequest),
      }),
    )

    expect(initRes.status).toBe(200)
    const sessionId = initRes.headers.get("mcp-session-id")
    expect(sessionId).toBeTruthy()

    const nextRes = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "GET",
        headers: {
          authorization: "Bearer token-1",
          accept: "text/event-stream",
          "mcp-session-id": sessionId!,
        },
      }),
    )

    expect(nextRes.status).toBe(200)
  })

  it("rejects introspection payloads with malformed space ids", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ...activeIntrospection({ grantId: "g1" }),
          space_ids: ["abc"],
        }),
        { status: 200 },
      ),
    )

    const app = createApp({
      issuer: "http://localhost:8791",
      oauthIntrospectionUrl: "https://api.inline.chat/oauth/introspect",
      oauthInternalSharedSecret: "secret",
    })

    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: { authorization: "Bearer token-1" },
      }),
    )

    expect(res.status).toBe(401)
    expect(await res.json()).toEqual({ error: "invalid_token" })
  })
})
