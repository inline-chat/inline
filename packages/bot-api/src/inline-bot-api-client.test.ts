import { describe, expect, it, vi } from "vitest"
import { InlineBotApiClient } from "./inline-bot-api-client.js"

describe("InlineBotApiClient", () => {
  it("defaults to header auth and /bot/<method>", async () => {
    let seenUrl = ""
    let seenAuth: string | null = null

    const client = new InlineBotApiClient({
      token: "123:abc",
      fetch: (async (input, init) => {
        seenUrl = String(input)
        seenAuth = new Headers(init?.headers).get("authorization")
        return new Response(JSON.stringify({ ok: true, result: { user: { id: 1, is_bot: true } } }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }) as any,
    })

    const res = await client.getMe()
    expect(res.ok).toBe(true)
    expect(seenUrl).toBe("https://api.inline.chat/bot/getMe")
    expect(seenAuth).toBe("Bearer 123:abc")
  })

  it("supports token-in-path auth mode", async () => {
    let seenUrl = ""
    let seenAuth: string | null = "not-set"

    const client = new InlineBotApiClient({
      token: "123:abc",
      authMode: "path",
      fetch: (async (input, init) => {
        seenUrl = String(input)
        seenAuth = new Headers(init?.headers).get("authorization")
        return new Response(JSON.stringify({ ok: true, result: { user: { id: 1, is_bot: true } } }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }) as any,
    })

    const res = await client.getMe()
    expect(res.ok).toBe(true)
    expect(seenUrl).toBe("https://api.inline.chat/bot123:abc/getMe")
    expect(seenAuth).toBeNull()
  })

  it("sends POST params as JSON by default", async () => {
    let seenMethod = ""
    let seenUrl = ""
    let seenBody = ""
    let seenContentType: string | null = null

    const client = new InlineBotApiClient({
      token: "t",
      fetch: (async (input, init) => {
        seenMethod = init?.method ?? ""
        seenUrl = String(input)
        seenContentType = new Headers(init?.headers).get("content-type")
        seenBody = init?.body ? String(init.body) : ""
        return new Response(JSON.stringify({ ok: true, result: { message: { message_id: 1 } } }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }) as any,
    })

    const res = await client.sendMessage({ chat_id: 42, text: "hello" })
    expect(res.ok).toBe(true)
    expect(seenMethod).toBe("POST")
    expect(seenUrl).toBe("https://api.inline.chat/bot/sendMessage")
    expect(seenContentType).toBe("application/json")
    expect(JSON.parse(seenBody)).toMatchObject({ chat_id: 42, text: "hello" })
  })

  it("supports POST query params", async () => {
    let seenUrl = ""
    let seenBody = "unset"

    const client = new InlineBotApiClient({
      token: "t",
      fetch: (async (input, init) => {
        seenUrl = String(input)
        seenBody = init?.body ? String(init.body) : ""
        return new Response(JSON.stringify({ ok: true, result: {} }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }) as any,
    })

    const res = await client.sendReaction(
      { chat_id: 42, message_id: 7, emoji: "🔥" },
      { postAs: "query" },
    )
    expect(res.ok).toBe(true)
    expect(seenUrl).toContain("https://api.inline.chat/bot/sendReaction?")
    expect(seenUrl).toContain("chat_id=42")
    expect(seenUrl).toContain("message_id=7")
    expect(seenUrl).toContain(encodeURIComponent("🔥"))
    expect(seenBody).toBe("")
  })

  it("sends GET params as query string", async () => {
    let seenUrl = ""

    const client = new InlineBotApiClient({
      token: "t",
      fetch: (async (input) => {
        seenUrl = String(input)
        return new Response(JSON.stringify({ ok: true, result: { messages: [] } }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }) as any,
    })

    const res = await client.getChatHistory({ chat_id: 42, limit: 20, offset_message_id: "5" })
    expect(res.ok).toBe(true)
    expect(seenUrl).toContain("https://api.inline.chat/bot/getChatHistory?")
    expect(seenUrl).toContain("chat_id=42")
    expect(seenUrl).toContain("limit=20")
    expect(seenUrl).toContain("offset_message_id=5")
  })

  it("requestRaw supports explicit query and body", async () => {
    let seenUrl = ""
    let seenBody = ""

    const client = new InlineBotApiClient({
      token: "t",
      fetch: (async (input, init) => {
        seenUrl = String(input)
        seenBody = init?.body ? String(init.body) : ""
        return new Response(JSON.stringify({ ok: true }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }) as any,
    })

    const res = await client.requestRaw<{ ok: boolean }>("/custom/path", {
      method: "POST",
      query: { a: 1, b: "x" },
      body: { c: true },
    })
    expect(res.status).toBe(200)
    expect(res.data.ok).toBe(true)
    expect(seenUrl).toContain("https://api.inline.chat/custom/path?")
    expect(seenUrl).toContain("a=1")
    expect(seenUrl).toContain("b=x")
    expect(JSON.parse(seenBody)).toEqual({ c: true })
  })

  it("uses global fetch when no fetch implementation is provided", async () => {
    const fetchMock = vi.fn(async () => {
      return new Response(JSON.stringify({ ok: true, result: { user: { id: 1, is_bot: true } } }), {
        status: 200,
        headers: { "content-type": "application/json" },
      })
    })

    const originalFetch = globalThis.fetch
    ;(globalThis as any).fetch = fetchMock
    try {
      const client = new InlineBotApiClient({ token: "t" })
      const res = await client.getMe()
      expect(res.ok).toBe(true)
      expect(fetchMock).toHaveBeenCalled()
    } finally {
      ;(globalThis as any).fetch = originalFetch
    }
  })
})
