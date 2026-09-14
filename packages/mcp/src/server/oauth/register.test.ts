import { afterEach, describe, expect, it, vi } from "vitest"
import { createApp } from "../app"

describe("oauth register proxy", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("forwards register request to oauth upstream", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          client_id: "client-1",
          redirect_uris: ["https://example.com/callback"],
        }),
        {
          status: 201,
          headers: { "content-type": "application/json" },
        },
      ),
    )

    const app = createApp({
      issuer: "http://localhost:8791",
      oauthProxyBaseUrl: "https://api.inline.chat",
      allowedHosts: ["localhost"],
      allowedOriginHosts: ["localhost"],
    })

    const res = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ redirect_uris: ["https://example.com/callback"] }),
      }),
    )

    expect(res.status).toBe(201)
    expect(await res.json()).toEqual({
      client_id: "client-1",
      redirect_uris: ["https://example.com/callback"],
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] ?? []
    expect(String(url)).toBe("https://api.inline.chat/oauth/register")
    expect((init as RequestInit).method).toBe("POST")
  })

  it("forwards alias /register to oauth upstream", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("ok", { status: 200 }))

    const app = createApp({
      issuer: "http://localhost:8791",
      oauthProxyBaseUrl: "https://api.inline.chat",
      allowedHosts: ["localhost"],
      allowedOriginHosts: ["localhost"],
    })

    const res = await app.fetch(new Request("http://localhost/register", { method: "POST" }))
    expect(res.status).toBe(200)

    const [url] = fetchMock.mock.calls[0] ?? []
    expect(String(url)).toBe("https://api.inline.chat/register")
  })
})
