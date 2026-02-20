import { describe, expect, it } from "vitest"
import { createApp } from "../app"
import { createMemoryStore } from "../store"

function base64Url(bytes: Uint8Array): string {
  return Buffer.from(bytes)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "")
}

async function encryptInlineToken(keyB64: string, plaintext: string): Promise<string> {
  const raw = Buffer.from(keyB64, "base64")
  const key = await crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt"])
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const pt = new TextEncoder().encode(plaintext)
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, pt)
  return `v1.${base64Url(iv)}.${base64Url(new Uint8Array(ct))}`
}

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

describe("/mcp", () => {
  it("requires Authorization", async () => {
    const app = createApp({ issuer: "http://localhost:8791", dbPath: ":memory:" })
    const res = await app.fetch(new Request("http://localhost/mcp", { method: "POST" }))
    expect(res.status).toBe(401)
    expect(res.headers.get("www-authenticate")).toContain("Bearer")
    expect(res.headers.get("www-authenticate")).toContain("scope=\"messages:read spaces:read\"")
  })

  it("rejects invalid authorization header format", async () => {
    const app = createApp({ issuer: "http://localhost:8791", dbPath: ":memory:" })
    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: { authorization: "Token xyz" },
      }),
    )
    expect(res.status).toBe(401)
    expect(await res.json()).toEqual({ error: "invalid_authorization" })
  })

  it("rejects invalid access tokens", async () => {
    const app = createApp({ issuer: "http://localhost:8791", dbPath: ":memory:" })
    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: { authorization: "Bearer mcp_at_nope" },
      }),
    )
    expect(res.status).toBe(401)
  })

  it("rate limits mcp initialization posts", async () => {
    const app = createApp({
      issuer: "http://localhost:8791",
      dbPath: ":memory:",
      endpointRateLimits: {
        sendEmailCode: { max: 10, windowMs: 10 * 60_000 },
        verifyEmailCode: { max: 20, windowMs: 10 * 60_000 },
        token: { max: 60, windowMs: 60_000 },
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

  it("rejects requests with unknown session id", async () => {
    const store = createMemoryStore()
    const now = Date.now()
    const client = store.createClient({ redirectUris: ["https://example.com/cb"], clientName: "x", nowMs: now })
    const grant = store.createGrant({
      id: "g1",
      clientId: client.clientId,
      inlineUserId: 1n,
      scope: "messages:read spaces:read",
      spaceIds: [10n],
      inlineTokenEnc: "v1.fake.fake",
      nowMs: now,
    })
    store.createAccessToken({ tokenHashHex: await (async () => {
      const data = new TextEncoder().encode("mcp_at_ok")
      const digest = await crypto.subtle.digest("SHA-256", data)
      const bytes = new Uint8Array(digest)
      let out = ""
      for (const b of bytes) out += b.toString(16).padStart(2, "0")
      return out
    })(), grantId: grant.id, nowMs: now, expiresAtMs: now + 60_000 })

    const app = createApp({ issuer: "http://localhost:8791", dbPath: ":memory:", store })
    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "GET",
        headers: { authorization: "Bearer mcp_at_ok", accept: "text/event-stream", "mcp-session-id": "missing" },
      }),
    )
    expect(res.status).toBe(404)
  })

  it("returns 500 when token decryption key is missing", async () => {
    const store = createMemoryStore()
    const now = Date.now()
    const client = store.createClient({ redirectUris: ["https://example.com/cb"], clientName: "x", nowMs: now })
    const grant = store.createGrant({
      id: "g1",
      clientId: client.clientId,
      inlineUserId: 1n,
      scope: "messages:read spaces:read",
      spaceIds: [10n],
      inlineTokenEnc: "v1.fake.fake",
      nowMs: now,
    })

    const accessToken = "mcp_at_ok"
    const hashHex = await (async () => {
      const data = new TextEncoder().encode(accessToken)
      const digest = await crypto.subtle.digest("SHA-256", data)
      const bytes = new Uint8Array(digest)
      let out = ""
      for (const b of bytes) out += b.toString(16).padStart(2, "0")
      return out
    })()

    store.createAccessToken({ tokenHashHex: hashHex, grantId: grant.id, nowMs: now, expiresAtMs: now + 60_000 })

    const app = createApp({
      issuer: "http://localhost:8791",
      dbPath: ":memory:",
      tokenEncryptionKeyB64: null,
      store,
    })

    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: {
          authorization: `Bearer ${accessToken}`,
          accept: "application/json, text/event-stream",
          "content-type": "application/json",
        },
        body: JSON.stringify(initRequest),
      }),
    )
    expect(res.status).toBe(500)
  })

  it("initializes a streamable http session when token is valid", async () => {
    const keyBytes = new Uint8Array(32)
    keyBytes.fill(7)
    const keyB64 = Buffer.from(keyBytes).toString("base64")

    const store = createMemoryStore()
    const now = Date.now()

    const client = store.createClient({ redirectUris: ["https://example.com/cb"], clientName: "x", nowMs: now })
    const grant = store.createGrant({
      id: "g1",
      clientId: client.clientId,
      inlineUserId: 1n,
      scope: "messages:read spaces:read messages:write",
      spaceIds: [10n],
      inlineTokenEnc: await encryptInlineToken(keyB64, "1:fake-inline-token"),
      nowMs: now,
    })

    const accessToken = "mcp_at_testtoken"
    const hashHex = await (async () => {
      const data = new TextEncoder().encode(accessToken)
      const digest = await crypto.subtle.digest("SHA-256", data)
      const bytes = new Uint8Array(digest)
      let out = ""
      for (const b of bytes) out += b.toString(16).padStart(2, "0")
      return out
    })()

    store.createAccessToken({ tokenHashHex: hashHex, grantId: grant.id, nowMs: now, expiresAtMs: now + 60_000 })

    const app = createApp({
      issuer: "http://localhost:8791",
      dbPath: ":memory:",
      tokenEncryptionKeyB64: keyB64,
      store,
    })

    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: {
          authorization: `Bearer ${accessToken}`,
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
    const keyBytes = new Uint8Array(32)
    keyBytes.fill(8)
    const keyB64 = Buffer.from(keyBytes).toString("base64")

    const store = createMemoryStore()
    const now = Date.now()

    const client = store.createClient({ redirectUris: ["https://example.com/cb"], clientName: "x", nowMs: now })

    const grant1 = store.createGrant({
      id: "g1",
      clientId: client.clientId,
      inlineUserId: 1n,
      scope: "messages:read spaces:read",
      spaceIds: [10n],
      inlineTokenEnc: await encryptInlineToken(keyB64, "1:fake-inline-token-1"),
      nowMs: now,
    })

    const grant2 = store.createGrant({
      id: "g2",
      clientId: client.clientId,
      inlineUserId: 2n,
      scope: "messages:read spaces:read",
      spaceIds: [10n],
      inlineTokenEnc: await encryptInlineToken(keyB64, "2:fake-inline-token-2"),
      nowMs: now,
    })

    const access1 = "mcp_at_1"
    const access2 = "mcp_at_2"

    const hash = async (t: string) => {
      const data = new TextEncoder().encode(t)
      const digest = await crypto.subtle.digest("SHA-256", data)
      const bytes = new Uint8Array(digest)
      let out = ""
      for (const b of bytes) out += b.toString(16).padStart(2, "0")
      return out
    }

    store.createAccessToken({ tokenHashHex: await hash(access1), grantId: grant1.id, nowMs: now, expiresAtMs: now + 60_000 })
    store.createAccessToken({ tokenHashHex: await hash(access2), grantId: grant2.id, nowMs: now, expiresAtMs: now + 60_000 })

    const app = createApp({
      issuer: "http://localhost:8791",
      dbPath: ":memory:",
      tokenEncryptionKeyB64: keyB64,
      store,
    })

    const initRes = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: {
          authorization: `Bearer ${access1}`,
          accept: "application/json, text/event-stream",
          "content-type": "application/json",
        },
        body: JSON.stringify(initRequest),
      }),
    )
    const sessionId = initRes.headers.get("mcp-session-id")
    expect(sessionId).toBeTruthy()

    const res = await app.fetch(
      new Request("http://localhost/mcp", {
        method: "GET",
        headers: {
          authorization: `Bearer ${access2}`,
          accept: "text/event-stream",
          "mcp-session-id": sessionId!,
        },
      }),
    )
    expect(res.status).toBe(403)
  })
})
