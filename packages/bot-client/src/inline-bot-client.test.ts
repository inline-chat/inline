import { describe, expect, it, vi } from "vitest"
import { InlineBotClient } from "./inline-bot-client.js"

describe("InlineBotClient", () => {
  it("defaults to header auth and /bot/<method>", async () => {
    let seenUrl = ""
    let seenAuth: string | null = null

    const client = new InlineBotClient({
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

    const client = new InlineBotClient({
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

    const client = new InlineBotClient({
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

    const client = new InlineBotClient({
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

    const client = new InlineBotClient({
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

  it("uses POST JSON for contextual message and thread methods", async () => {
    const calls: Array<{ url: string; method: string; body: unknown }> = []
    const client = new InlineBotClient({
      token: "t",
      fetch: (async (input, init) => {
        calls.push({
          url: String(input),
          method: init?.method ?? "",
          body: init?.body ? JSON.parse(String(init.body)) : undefined,
        })
        return new Response(JSON.stringify({ ok: true, result: { messages: [], chat: {} } }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }) as any,
    })

    await client.getMessages({ chat_id: 42, message_ids: [7, 8] })
    await client.searchMessages({ chat_id: 42, query: "incident", limit: 20 })
    await client.createThread({ title: "Triage", participants: [9] })
    await client.createReplyThread({ chat_id: 42, message_id: 7, title: "Follow-up" })

    expect(calls).toEqual([
      {
        url: "https://api.inline.chat/bot/getMessages",
        method: "POST",
        body: { chat_id: 42, message_ids: [7, 8] },
      },
      {
        url: "https://api.inline.chat/bot/searchMessages",
        method: "POST",
        body: { chat_id: 42, query: "incident", limit: 20 },
      },
      {
        url: "https://api.inline.chat/bot/createThread",
        method: "POST",
        body: { title: "Triage", participants: [9] },
      },
      {
        url: "https://api.inline.chat/bot/createReplyThread",
        method: "POST",
        body: { chat_id: 42, message_id: 7, title: "Follow-up" },
      },
    ])
  })

  it("uses GET for getChat", async () => {
    let seenUrl = ""
    let seenMethod = ""

    const client = new InlineBotClient({
      token: "t",
      fetch: (async (input, init) => {
        seenUrl = String(input)
        seenMethod = init?.method ?? ""
        return new Response(JSON.stringify({ ok: true, result: { chat: { chat_id: 42 } } }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }) as any,
    })

    const res = await client.getChat({ user_id: 7 })
    expect(res.ok).toBe(true)
    expect(seenMethod).toBe("GET")
    expect(seenUrl).toContain("https://api.inline.chat/bot/getChat?")
    expect(seenUrl).toContain("user_id=7")
  })

  it("exposes forwarding, pinning, participant, and thread title methods", async () => {
    const calls: Array<{ url: string; method: string; body?: unknown }> = []
    const client = new InlineBotClient({
      token: "t",
      fetch: (async (input, init) => {
        calls.push({
          url: String(input),
          method: init?.method ?? "",
          body: init?.body ? JSON.parse(String(init.body)) : undefined,
        })
        return new Response(JSON.stringify({ ok: true, result: {} }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }) as any,
    })

    await client.forwardMessage({ chat_id: 9, from_chat_id: 8, message_id: 7 })
    await client.pinMessage({ chat_id: 9, message_id: 7 })
    await client.unpinMessage({ chat_id: 9, message_id: 7 })
    await client.getChatParticipant({ chat_id: 9, user_id: 6 })
    await client.getChatParticipantCount({ chat_id: 9 })
    await client.addThreadParticipant({ chat_id: 9, user_id: 5 })
    await client.removeThreadParticipant({ chat_id: 9, user_id: 5 })
    await client.setThreadTitle({ chat_id: 9, title: "Triage" })

    expect(calls.map(({ url, method }) => ({ url, method }))).toEqual([
      { url: "https://api.inline.chat/bot/forwardMessage", method: "POST" },
      { url: "https://api.inline.chat/bot/pinMessage", method: "POST" },
      { url: "https://api.inline.chat/bot/unpinMessage", method: "POST" },
      { url: "https://api.inline.chat/bot/getChatParticipant?chat_id=9&user_id=6", method: "GET" },
      { url: "https://api.inline.chat/bot/getChatParticipantCount?chat_id=9", method: "GET" },
      { url: "https://api.inline.chat/bot/addThreadParticipant", method: "POST" },
      { url: "https://api.inline.chat/bot/removeThreadParticipant", method: "POST" },
      { url: "https://api.inline.chat/bot/setThreadTitle", method: "POST" },
    ])
  })

  it("requestRaw supports explicit query and body", async () => {
    let seenUrl = ""
    let seenBody = ""

    const client = new InlineBotClient({
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

  it("requestRaw supports text responses and complex query values", async () => {
    let seenUrl = ""

    const client = new InlineBotClient({
      token: "t",
      fetch: (async (input) => {
        seenUrl = String(input)
        return new Response("plain text", {
          status: 202,
          headers: { "content-type": "text/plain" },
        })
      }) as any,
    })

    const res = await client.requestRaw<string>("custom/path", {
      method: "GET",
      query: {
        nil: null,
        flag: false,
        big: 12n,
        obj: { a: 1 },
        skip: undefined,
      },
    })

    expect(res.status).toBe(202)
    expect(res.data).toBe("plain text")
    expect(seenUrl).toContain("https://api.inline.chat/custom/path?")
    expect(seenUrl).toContain("nil=null")
    expect(seenUrl).toContain("flag=false")
    expect(seenUrl).toContain("big=12")
    expect(seenUrl).toContain(`obj=${encodeURIComponent(JSON.stringify({ a: 1 }))}`)
    expect(seenUrl).not.toContain("skip=")
  })

  it("uses GET for getMyCommands", async () => {
    let seenUrl = ""
    let seenMethod = ""

    const client = new InlineBotClient({
      token: "t",
      fetch: (async (input, init) => {
        seenUrl = String(input)
        seenMethod = init?.method ?? ""
        return new Response(JSON.stringify({ ok: true, result: { commands: [] } }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }) as any,
    })

    const res = await client.getMyCommands()
    expect(res.ok).toBe(true)
    expect(seenMethod).toBe("GET")
    expect(seenUrl).toBe("https://api.inline.chat/bot/getMyCommands")
  })

  it("uses POST JSON for setMyCommands", async () => {
    let seenUrl = ""
    let seenMethod = ""
    let seenBody = ""

    const client = new InlineBotClient({
      token: "t",
      fetch: (async (input, init) => {
        seenUrl = String(input)
        seenMethod = init?.method ?? ""
        seenBody = init?.body ? String(init.body) : ""
        return new Response(JSON.stringify({ ok: true, result: {} }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }) as any,
    })

    const res = await client.setMyCommands({
      commands: [{ command: "start", description: "Start the bot", sort_order: 1 }],
    })

    expect(res.ok).toBe(true)
    expect(seenMethod).toBe("POST")
    expect(seenUrl).toBe("https://api.inline.chat/bot/setMyCommands")
    expect(JSON.parse(seenBody)).toEqual({
      commands: [{ command: "start", description: "Start the bot", sort_order: 1 }],
    })
  })

  it("uses POST JSON for editMessageText and deleteMessage", async () => {
    const calls: Array<{ url: string; method: string; body: unknown }> = []

    const client = new InlineBotClient({
      token: "t",
      fetch: (async (input, init) => {
        calls.push({
          url: String(input),
          method: init?.method ?? "",
          body: init?.body ? JSON.parse(String(init.body)) : undefined,
        })
        return new Response(JSON.stringify({ ok: true, result: { message: { message_id: 7 } } }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }) as any,
    })

    const edit = await client.editMessageText({ chat_id: 42, message_id: 7, text: "updated" })
    const deleted = await client.deleteMessage({ chat_id: 42, message_id: 7 })

    expect(edit.ok).toBe(true)
    expect(deleted.ok).toBe(true)
    expect(calls).toEqual([
      {
        url: "https://api.inline.chat/bot/editMessageText",
        method: "POST",
        body: { chat_id: 42, message_id: 7, text: "updated" },
      },
      {
        url: "https://api.inline.chat/bot/deleteMessage",
        method: "POST",
        body: { chat_id: 42, message_id: 7 },
      },
    ])
  })

  it("uses POST for deleteMyCommands", async () => {
    let seenUrl = ""
    let seenMethod = ""

    const client = new InlineBotClient({
      token: "t",
      fetch: (async (input, init) => {
        seenUrl = String(input)
        seenMethod = init?.method ?? ""
        return new Response(JSON.stringify({ ok: true, result: {} }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }) as any,
    })

    const res = await client.deleteMyCommands()
    expect(res.ok).toBe(true)
    expect(seenMethod).toBe("POST")
    expect(seenUrl).toBe("https://api.inline.chat/bot/deleteMyCommands")
  })

  it("supports polling, webhook, action, and file transports", async () => {
    const calls: Array<{ url: string; method: string; body: unknown }> = []
    const client = new InlineBotClient({
      token: "t",
      fetch: (async (input, init) => {
        calls.push({
          url: String(input),
          method: init?.method ?? "",
          body: init?.body ? JSON.parse(String(init.body)) : undefined,
        })
        return new Response(JSON.stringify({ ok: true, result: [] }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }) as any,
    })

    await client.getUpdates({ timeout: 20, allowed_updates: ["message"] })
    await client.setWebhook({ url: "https://agent.example/inline", secret_token: "optional" })
    await client.deleteWebhook({ drop_pending_updates: false })
    await client.sendChatAction({ chat_id: 42, action: "typing" })
    await client.answerMessageAction({ interaction_id: 9, text: "Working" })
    await client.deleteReaction({ chat_id: 42, message_id: 7, emoji: "🔥" })
    await client.getFile({ file_id: "INV_example" })
    await client.getWebhookInfo()

    expect(calls.map(({ url, method }) => ({ url, method }))).toEqual([
      { url: "https://api.inline.chat/bot/getUpdates?timeout=20&allowed_updates=%5B%22message%22%5D", method: "GET" },
      { url: "https://api.inline.chat/bot/setWebhook", method: "POST" },
      { url: "https://api.inline.chat/bot/deleteWebhook", method: "POST" },
      { url: "https://api.inline.chat/bot/sendChatAction", method: "POST" },
      { url: "https://api.inline.chat/bot/answerMessageAction", method: "POST" },
      { url: "https://api.inline.chat/bot/deleteReaction", method: "POST" },
      { url: "https://api.inline.chat/bot/getFile?file_id=INV_example", method: "GET" },
      { url: "https://api.inline.chat/bot/getWebhookInfo", method: "GET" },
    ])
  })

  it("uploads bot files through the Bot multipart endpoint", async () => {
    let seenBody: FormData | undefined
    let seenAuth: string | null = null
    let seenUrl = ""
    const client = new InlineBotClient({
      token: "t",
      fetch: (async (input, init) => {
        seenUrl = String(input)
        seenBody = init?.body as FormData
        seenAuth = new Headers(init?.headers).get("authorization")
        return new Response(JSON.stringify({ ok: true, result: { file: { file_id: "INP_example", file_size: 5, mime_type: "image/jpeg" } } }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }) as any,
    })
    const result = await client.uploadFile({
      type: "photo",
      file: new Blob(["photo"], { type: "image/jpeg" }),
      file_name: "photo.jpg",
      thumbnail: new Blob(["thumb"], { type: "image/jpeg" }),
      width: 640,
      height: 480,
      duration: 3,
      is_animated: false,
      has_audio: true,
      waveform_base64: "AAE=",
    })
    expect(seenAuth).toBe("Bearer t")
    expect(seenUrl).toBe("https://api.inline.chat/bot/uploadFile")
    expect(seenBody?.get("type")).toBe("photo")
    expect(seenBody?.get("is_animated")).toBe("false")
    expect(seenBody?.get("has_audio")).toBe("true")
    expect(seenBody?.get("waveform_base64")).toBe("AAE=")
    expect(result).toEqual({
      ok: true,
      result: { file: { file_id: "INP_example", file_size: 5, mime_type: "image/jpeg" } },
    })
    await client.uploadFile({
      type: "document",
      file: new Blob(["doc"], { type: "application/octet-stream" }),
    })
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
      const client = new InlineBotClient({ token: "t" })
      const res = await client.getMe()
      expect(res.ok).toBe(true)
      expect(fetchMock).toHaveBeenCalled()
    } finally {
      ;(globalThis as any).fetch = originalFetch
    }
  })
})
