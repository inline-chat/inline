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

  it("syncs bot commands on gateway start", async () => {
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
    expect(fetchMock).toHaveBeenCalledTimes(1)

    const firstCall = fetchMock.mock.calls[0]
    expect(String(firstCall?.[0])).toBe("https://api.inline.chat/bot/setMyCommands")
    const setBody = JSON.parse(String(firstCall?.[1]?.body)) as {
      commands: Array<{ command: string; description: string }>
    }
    const names = setBody.commands.map((entry) => entry.command)
    expect(names).toContain("help")
    expect(names).toContain("status")
    expect(names).toContain("model")
    expect(names).toContain("exec")
    expect(names).toContain("tools")
    expect(names.indexOf("tools")).toBeLessThan(names.indexOf("model"))
    expect(setBody.commands).toContainEqual({
      command: "reasoning",
      description: "Toggle reasoning visibility.",
    })
    expect(setBody.commands).toContainEqual({
      command: "subagents",
      description: "List, kill, log, spawn, or steer subagent runs for this session.",
    })
    expect(setBody.commands).toContainEqual({
      command: "focus",
      description: "Bind this Inline conversation to a session target.",
    })
  }, 30_000)

  it("clears bot commands when commands.native is disabled", async () => {
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
        commands: { native: false },
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
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(String(fetchMock.mock.calls[0]?.[0])).toBe("https://api.inline.chat/bot/deleteMyCommands")
    expect(logger.info).toHaveBeenCalledWith(
      '[inline] bot commands cleared for account "default"',
    )
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

  it("honors per-account native command enablement", async () => {
    const fetchMock = vi.fn(async () =>
      new Response(JSON.stringify({ ok: true, result: {} }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    )
    globalThis.fetch = fetchMock as typeof fetch

    const { syncInlineNativeCommands } = await import("./bot-commands-sync")
    const logger = {
      info: vi.fn(),
      warn: vi.fn(),
    }
    const result = await syncInlineNativeCommands({
      cfg: {
        commands: { native: false },
        channels: {
          inline: {
            accounts: {
              default: { token: "default-token" },
              work: {
                token: "work-token",
                commands: { native: true },
              },
            },
          },
        },
      } satisfies OpenClawConfig,
      logger,
    })

    expect(result).toEqual({
      attempted: 2,
      synced: 2,
      failed: 0,
    })
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(String(fetchMock.mock.calls[0]?.[0])).toBe("https://api.inline.chat/bot/deleteMyCommands")
    expect(String(fetchMock.mock.calls[1]?.[0])).toBe("https://api.inline.chat/bot/setMyCommands")
    expect(logger.info).toHaveBeenCalledWith(
      '[inline] bot commands cleared for account "default"',
    )
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
    const firstSetBody = JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body)) as {
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
    const secondSetBody = JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body)) as {
      commands: Array<{ command: string }>
    }
    const secondNames = secondSetBody.commands.map((entry) => entry.command)
    expect(secondNames).toContain("config")
    expect(secondNames).toContain("debug")
  })

  it("scopes native skill commands per account route", async () => {
    vi.resetModules()

    const listSkillCommandsForAgents = vi.fn(
      ({ agentIds }: { agentIds?: string[] }) =>
        agentIds?.[0] === "ops"
          ? [{ name: "ops_skill", description: "Ops skill" }]
          : [{ name: "main_skill", description: "Main skill" }],
    )
    const listNativeCommandSpecsForConfig = vi.fn(
      (
        _cfg: OpenClawConfig,
        params?: {
          skillCommands?: Array<{ name: string; description: string }>
        },
      ) => params?.skillCommands ?? [],
    )
    const getPluginCommandSpecs = vi.fn(() => [])

    vi.doMock("openclaw/plugin-sdk/skill-commands-runtime", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk/skill-commands-runtime")
      return {
        ...actual,
        listSkillCommandsForAgents,
      }
    })
    vi.doMock("openclaw/plugin-sdk/native-command-registry", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk/native-command-registry")
      return {
        ...actual,
        listNativeCommandSpecsForConfig,
      }
    })
    vi.doMock("openclaw/plugin-sdk/plugin-runtime", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk/plugin-runtime")
      return {
        ...actual,
        getPluginCommandSpecs,
      }
    })

    const fetchMock = vi.fn(async () =>
      new Response(JSON.stringify({ ok: true, result: {} }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    )
    globalThis.fetch = fetchMock as typeof fetch

    const { syncInlineNativeCommands } = await import("./bot-commands-sync")
    await syncInlineNativeCommands({
      cfg: {
        commands: { nativeSkills: true },
        agents: {
          list: [{ id: "main", default: true }, { id: "ops" }],
        },
        bindings: [
          {
            agentId: "ops",
            match: { channel: "inline", accountId: "work" },
          },
        ],
        channels: {
          inline: {
            accounts: {
              default: { token: "default-token" },
              work: { token: "work-token" },
            },
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
      agentIds: ["main"],
    })
    expect(listSkillCommandsForAgents).toHaveBeenCalledWith({
      cfg: expect.any(Object),
      agentIds: ["ops"],
    })

    const bodies = fetchMock.mock.calls.map((call) => JSON.parse(String(call[1]?.body)) as {
      commands: Array<{ command: string }>
    })
    expect(bodies.map((body) => body.commands.map((entry) => entry.command))).toEqual([
      ["main_skill"],
      ["ops_skill"],
    ])
  })

  it("skips duplicate bot-token accounts during bot command sync", async () => {
    const fetchMock = vi.fn(async () =>
      new Response(JSON.stringify({ ok: true, result: {} }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    )
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
            token: "shared-token",
            accounts: {
              ops: { token: "shared-token" },
            },
          },
        },
      } satisfies OpenClawConfig,
      logger,
    })

    expect(result).toEqual({
      attempted: 2,
      synced: 1,
      failed: 1,
    })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(logger.warn).toHaveBeenCalledWith(
      '[inline] bot command sync skipped for account "ops": Duplicate Inline bot token: account "ops" shares a token with account "default". Keep one owner account per Inline bot token.',
    )
  }, 30_000)

  it("uses plugin-sdk native/skill/plugin command helpers when available", async () => {
    vi.resetModules()

    const listSkillCommandsForAgents = vi.fn(() => [
      { name: "weather_skill", description: "Weather skill" },
    ])
    const listNativeCommandSpecsForConfig = vi.fn(
      (
        _cfg: OpenClawConfig,
        params?: {
          provider?: string
          skillCommands?: Array<{ name: string; description: string }>
        },
      ) => [
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
      { name: "long_desc", description: "x".repeat(300) },
    ])

    vi.doMock("openclaw/plugin-sdk/skill-commands-runtime", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk/skill-commands-runtime")
      return {
        ...actual,
        listSkillCommandsForAgents,
      }
    })
    vi.doMock("openclaw/plugin-sdk/native-command-registry", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk/native-command-registry")
      return {
        ...actual,
        listNativeCommandSpecsForConfig,
      }
    })
    vi.doMock("openclaw/plugin-sdk/plugin-runtime", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk/plugin-runtime")
      return {
        ...actual,
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
    const logger = {
      info: vi.fn(),
      warn: vi.fn(),
    }
    await syncInlineNativeCommands({
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

    expect(listSkillCommandsForAgents).toHaveBeenCalledWith({
      cfg: expect.any(Object),
      agentIds: ["main"],
    })
    expect(listNativeCommandSpecsForConfig).toHaveBeenCalledWith(
      expect.any(Object),
      expect.objectContaining({ provider: "inline" }),
    )
    expect(getPluginCommandSpecs).toHaveBeenCalledWith("inline", {
      config: expect.any(Object),
    })

    const setBody = JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body)) as {
      commands: Array<{ command: string; description: string }>
    }
    const names = setBody.commands.map((entry) => entry.command)
    expect(names).toContain("status")
    expect(names).toContain("weather_skill")
    expect(names).toContain("plugin_cmd")
    expect(names).not.toContain("bad-cmd")
    expect(setBody.commands.find((entry) => entry.command === "long_desc")?.description).toHaveLength(256)
    expect(logger.warn).toHaveBeenCalledWith(
      "[inline] bot command sync truncated description for /long_desc to 256 characters",
    )
  })
})
