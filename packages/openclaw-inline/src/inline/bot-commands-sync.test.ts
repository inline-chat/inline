import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk"

describe("inline/bot-commands-sync", () => {
  const originalFetch = globalThis.fetch

  beforeEach(() => {
    vi.restoreAllMocks()
  })

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  it("syncs native commands on gateway start", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.endsWith("/bot/deleteMyCommands") || url.endsWith("/bot/setMyCommands")) {
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

    const { syncInlineNativeCommands } = await import("./bot-commands-sync")
    const logger = {
      info: vi.fn(),
      warn: vi.fn(),
    }
    const result = await syncInlineNativeCommands({
      cfg: {
        channels: {
          inline: {
            token: "inline-bot-token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      logger,
    })

    expect(result).toEqual({
      attempted: 1,
      synced: 1,
      failed: 0,
    })
    expect(fetchMock).toHaveBeenCalledTimes(2)

    const firstCall = fetchMock.mock.calls[0]
    const secondCall = fetchMock.mock.calls[1]
    expect(String(firstCall?.[0])).toBe("https://api.inline.chat/bot/deleteMyCommands")
    expect(String(secondCall?.[0])).toBe("https://api.inline.chat/bot/setMyCommands")
    const setBody = JSON.parse(String(secondCall?.[1]?.body)) as {
      commands: Array<{ command: string; description: string }>
    }
    const names = setBody.commands.map((entry) => entry.command)
    expect(names).toContain("help")
    expect(names).toContain("status")
    expect(names).toContain("model")
    expect(names).toContain("exec")
  })

  it("clears native commands when commands.native is disabled", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.endsWith("/bot/deleteMyCommands") || url.endsWith("/bot/setMyCommands")) {
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

    const { syncInlineNativeCommands } = await import("./bot-commands-sync")
    const result = await syncInlineNativeCommands({
      cfg: {
        commands: { native: false },
        channels: {
          inline: {
            token: "inline-bot-token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      logger: {
        info: vi.fn(),
        warn: vi.fn(),
      },
    })

    expect(result).toEqual({
      attempted: 1,
      synced: 1,
      failed: 0,
    })
    const setCall = fetchMock.mock.calls[1]
    expect(String(setCall?.[0])).toBe("https://api.inline.chat/bot/setMyCommands")
    expect(JSON.parse(String(setCall?.[1]?.body))).toEqual({
      commands: [],
    })
  })

  it("supports channels.inline.commands.native override", async () => {
    const { shouldSyncInlineNativeCommands } = await import("./bot-commands-sync")
    const cfg = {
      commands: { native: false },
      channels: {
        inline: {
          commands: {
            native: true,
          },
        },
      },
    } as OpenClawConfig

    expect(shouldSyncInlineNativeCommands(cfg)).toBe(true)
  })

  it("includes config/debug commands only when enabled", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.endsWith("/bot/deleteMyCommands") || url.endsWith("/bot/setMyCommands")) {
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

    const { syncInlineNativeCommands } = await import("./bot-commands-sync")

    await syncInlineNativeCommands({
      cfg: {
        channels: {
          inline: {
            token: "inline-bot-token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      logger: {
        info: vi.fn(),
        warn: vi.fn(),
      },
    })
    const firstSetBody = JSON.parse(String(fetchMock.mock.calls[1]?.[1]?.body)) as {
      commands: Array<{ command: string }>
    }
    const firstNames = firstSetBody.commands.map((entry) => entry.command)
    expect(firstNames).not.toContain("config")
    expect(firstNames).not.toContain("debug")

    fetchMock.mockClear()

    await syncInlineNativeCommands({
      cfg: {
        commands: {
          config: true,
          debug: true,
        },
        channels: {
          inline: {
            token: "inline-bot-token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      logger: {
        info: vi.fn(),
        warn: vi.fn(),
      },
    })
    const secondSetBody = JSON.parse(String(fetchMock.mock.calls[1]?.[1]?.body)) as {
      commands: Array<{ command: string }>
    }
    const secondNames = secondSetBody.commands.map((entry) => entry.command)
    expect(secondNames).toContain("config")
    expect(secondNames).toContain("debug")
  })

  it("uses plugin-sdk native/skill/plugin command helpers when available", async () => {
    vi.resetModules()

    const listSkillCommandsForAgents = vi.fn(() => [
      { name: "weather_skill", description: "Weather skill" },
    ])
    const listNativeCommandSpecsForConfig = vi.fn(
      (_cfg: OpenClawConfig, params?: { skillCommands?: Array<{ name: string; description: string }> }) => [
        { name: "status", description: "Show current status." },
        ...(params?.skillCommands ?? []).map((entry) => ({
          name: entry.name,
          description: entry.description,
        })),
      ],
    )
    const getPluginCommandSpecs = vi.fn(() => [
      { name: "plugin_cmd", description: "Plugin command" },
      { name: "bad-cmd", description: "Should be skipped" },
    ])

    vi.doMock("openclaw/plugin-sdk", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk")
      return {
        ...actual,
        listSkillCommandsForAgents,
        listNativeCommandSpecsForConfig,
        getPluginCommandSpecs,
      }
    })

    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.endsWith("/bot/deleteMyCommands") || url.endsWith("/bot/setMyCommands")) {
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

    const { syncInlineNativeCommands } = await import("./bot-commands-sync")
    await syncInlineNativeCommands({
      cfg: {
        channels: {
          inline: {
            token: "inline-bot-token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      logger: {
        info: vi.fn(),
        warn: vi.fn(),
      },
    })

    expect(listSkillCommandsForAgents).toHaveBeenCalledWith({
      cfg: expect.any(Object),
    })
    expect(listNativeCommandSpecsForConfig).toHaveBeenCalled()
    expect(getPluginCommandSpecs).toHaveBeenCalled()

    const setBody = JSON.parse(String(fetchMock.mock.calls[1]?.[1]?.body)) as {
      commands: Array<{ command: string }>
    }
    const names = setBody.commands.map((entry) => entry.command)
    expect(names).toContain("status")
    expect(names).toContain("weather_skill")
    expect(names).toContain("plugin_cmd")
    expect(names).not.toContain("bad-cmd")
  })
})
