import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk"

describe("inline/bot-commands-tool", () => {
  const originalFetch = globalThis.fetch

  beforeEach(() => {
    vi.restoreAllMocks()
  })

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  it("returns null when config is missing", async () => {
    const { createInlineBotCommandsTool } = await import("./bot-commands-tool")
    expect(createInlineBotCommandsTool({})).toBeNull()
  })

  it("supports set/get/delete command management via Inline Bot API", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL, _init?: RequestInit) => {
      const url = String(input)
      if (url.endsWith("/bot/setMyCommands")) {
        return new Response(JSON.stringify({ ok: true, result: {} }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }
      if (url.endsWith("/bot/getMyCommands")) {
        return new Response(
          JSON.stringify({
            ok: true,
            result: {
              commands: [{ command: "weather", description: "Get weather", sort_order: 1 }],
            },
          }),
          {
            status: 200,
            headers: { "content-type": "application/json" },
          },
        )
      }
      if (url.endsWith("/bot/deleteMyCommands")) {
        return new Response(JSON.stringify({ ok: true, result: {} }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }
      return new Response(JSON.stringify({ ok: false, error_code: 404, description: "not found" }), {
        status: 404,
        headers: { "content-type": "application/json" },
      })
    })
    globalThis.fetch = fetchMock as typeof fetch

    const { createInlineBotCommandsTool } = await import("./bot-commands-tool")

    const tool = createInlineBotCommandsTool({
      config: {
        channels: {
          inline: {
            token: "inline-bot-token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      agentAccountId: "default",
    })

    const setResult = await tool?.execute("tool-1", {
      action: "set",
      commands: [{ command: "weather", description: "Get weather", sort_order: 1 }],
    })
    expect(setResult).toMatchObject({
      details: {
        ok: true,
        action: "set",
      },
    })

    const firstCall = fetchMock.mock.calls[0]
    expect(firstCall).toBeDefined()
    if (!firstCall) throw new Error("missing first fetch call")
    const [setInput, setInit] = firstCall
    expect(String(setInput)).toBe("https://api.inline.chat/bot/setMyCommands")
    expect(setInit?.method).toBe("POST")
    const setHeaders = setInit?.headers instanceof Headers ? setInit.headers : new Headers(setInit?.headers)
    expect(setHeaders.get("authorization")).toBe("Bearer inline-bot-token")
    expect(JSON.parse(String(setInit?.body))).toEqual({
      commands: [{ command: "weather", description: "Get weather", sort_order: 1 }],
    })

    const getResult = await tool?.execute("tool-2", { action: "get" })
    expect(getResult).toMatchObject({
      details: {
        ok: true,
        action: "get",
        commands: [{ command: "weather", description: "Get weather", sort_order: 1 }],
      },
    })
    const secondCall = fetchMock.mock.calls[1]
    expect(secondCall?.[1]?.method).toBe("GET")
    expect(String(secondCall?.[0])).toBe("https://api.inline.chat/bot/getMyCommands")

    const deleteResult = await tool?.execute("tool-3", { action: "delete" })
    expect(deleteResult).toMatchObject({
      details: {
        ok: true,
        action: "delete",
      },
    })
    const thirdCall = fetchMock.mock.calls[2]
    expect(thirdCall?.[1]?.method).toBe("POST")
    expect(String(thirdCall?.[0])).toBe("https://api.inline.chat/bot/deleteMyCommands")
  })

  it("normalizes leading slash command names for set", async () => {
    const fetchMock = vi.fn(async () =>
      new Response(JSON.stringify({ ok: true, result: {} }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    )
    globalThis.fetch = fetchMock as typeof fetch

    const { createInlineBotCommandsTool } = await import("./bot-commands-tool")
    const tool = createInlineBotCommandsTool({
      config: {
        channels: {
          inline: {
            token: "inline-bot-token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
    })

    await tool?.execute("tool-slash", {
      action: "set",
      commands: [{ command: "/weather", description: "Get weather" }],
    })

    const firstCall = fetchMock.mock.calls[0]
    expect(firstCall).toBeDefined()
    if (!firstCall) throw new Error("missing first fetch call")
    expect(JSON.parse(String(firstCall[1]?.body))).toEqual({
      commands: [{ command: "weather", description: "Get weather" }],
    })
  })

  it("falls back to path token auth when header auth returns unauthorized", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.endsWith("/bot/setMyCommands")) {
        return new Response(JSON.stringify({ ok: false, error_code: 401, description: "Unauthorized" }), {
          status: 401,
          headers: { "content-type": "application/json" },
        })
      }
      if (url.endsWith("/botinline-bot-token/setMyCommands")) {
        return new Response(JSON.stringify({ ok: true, result: {} }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }
      return new Response(JSON.stringify({ ok: false, error_code: 404, description: "not found" }), {
        status: 404,
        headers: { "content-type": "application/json" },
      })
    })
    globalThis.fetch = fetchMock as typeof fetch

    const { createInlineBotCommandsTool } = await import("./bot-commands-tool")
    const tool = createInlineBotCommandsTool({
      config: {
        channels: {
          inline: {
            token: "inline-bot-token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
    })

    await tool?.execute("tool-fallback", {
      action: "set",
      commands: [{ command: "weather", description: "Get weather" }],
    })

    expect(fetchMock).toHaveBeenCalledTimes(2)

    const firstCall = fetchMock.mock.calls[0]
    const secondCall = fetchMock.mock.calls[1]

    expect(String(firstCall?.[0])).toBe("https://api.inline.chat/bot/setMyCommands")
    expect(String(secondCall?.[0])).toBe("https://api.inline.chat/botinline-bot-token/setMyCommands")

    const firstHeaders =
      firstCall?.[1]?.headers instanceof Headers ? firstCall[1].headers : new Headers(firstCall?.[1]?.headers)
    expect(firstHeaders.get("authorization")).toBe("Bearer inline-bot-token")

    const secondHeaders =
      secondCall?.[1]?.headers instanceof Headers ? secondCall[1].headers : new Headers(secondCall?.[1]?.headers)
    expect(secondHeaders.get("authorization")).toBeNull()
  })
})
