import { describe, expect, it, vi } from "vitest"
import type { OpenClawPluginApi, PluginRuntime } from "openclaw/plugin-sdk"
import { buildInlineVersionText, createInlineMaintenanceCommands } from "./maintenance-command"

const { syncInlineCatalogs } = vi.hoisted(() => ({
  syncInlineCatalogs: vi.fn(async () => ({
    reason: "manual" as const,
    completedAt: "2026-09-04T10:00:00.000Z",
    commands: { attempted: 1, synced: 1, failed: 0 },
    skills: { attempted: 1, synced: 1, failed: 0 },
  })),
}))

vi.mock("./catalog-sync", () => ({
  getLastInlineCatalogSyncStatus: () => undefined,
  syncInlineCatalogs,
}))

function api(options: {
  version?: string
  config?: unknown
  inspection?: unknown
  request?: () => Promise<unknown>
} = {}): OpenClawPluginApi {
  return {
    id: "inline",
    version: options.version ?? "0.0.66",
    runtime: {
      version: "2026.8.2",
      gateway: {
        isAvailable: vi.fn(async () => true),
        request: vi.fn(options.request ?? (async () => options.inspection ?? ({
          plugin: { version: "0.0.66" },
          source: { kind: "clawhub" },
        }))),
      },
    } as unknown as PluginRuntime,
    config: options.config ?? {
      plugins: {
        installs: {
          inline: {
            source: "clawhub",
            version: "0.0.66",
            resolvedVersion: "0.0.66",
            resolvedAt: "2026-09-03T02:44:00Z",
            installedAt: "2026-09-03T02:45:00Z",
          },
        },
      },
    },
    logger: {
      info: vi.fn(),
      warn: vi.fn(),
      error: vi.fn(),
    },
  } as unknown as OpenClawPluginApi
}

async function runVersionCommand(pluginApi: OpenClawPluginApi): Promise<string> {
  const command = createInlineMaintenanceCommands(pluginApi)[1]!
  const result = await command.handler({
    isAuthorizedSender: true,
    args: "",
  } as never)
  return result.text
}

describe("inline maintenance commands", () => {
  it("reports safe plugin install metadata without paths or package specs", () => {
    const text = buildInlineVersionText(api())

    expect(text).toContain("Plugin version: 0.0.66")
    expect(text).toContain("OpenClaw version: 2026.8.2")
    expect(text).toContain("Install source: clawhub")
    expect(text).toContain("Last install/update: 2026-09-03T02:45:00.000Z")
    expect(text).toContain("Last catalog sync: not run in this process")
    expect(text).not.toContain("installPath")
    expect(text).not.toContain("sourcePath")
    expect(text).not.toContain("spec")
  })

  it("registers native sync and version commands with argument validation", async () => {
    const pluginApi = api()
    const commands = createInlineMaintenanceCommands(pluginApi)
    expect(commands.map((command) => command.name)).toEqual(["inline-sync", "inline-version"])
    expect(commands.map((command) => command.nativeNames?.inline)).toEqual([
      "inline_sync",
      "inline_version",
    ])

    const version = commands[1]!
    await expect(version.handler({
      isAuthorizedSender: true,
      args: "unexpected",
    } as never)).resolves.toEqual({ text: "Usage: /inline_version" })
    await expect(version.handler({
      isAuthorizedSender: false,
    } as never)).resolves.toEqual({ text: "This Inline command is not available to this sender." })
    await expect(version.handler({
      isAuthorizedSender: true,
      args: "",
    } as never)).resolves.toEqual({ text: buildInlineVersionText(pluginApi) })
    expect(pluginApi.runtime.gateway.request).toHaveBeenCalledWith("plugins.inspect", {
      pluginId: "inline",
    })
  })

  it("uses current plugins.inspect installation metadata without exposing paths or package specs", async () => {
    const pluginApi = api({
      version: "0.0.70",
      config: {},
      inspection: {
        plugin: {
          version: "0.0.70",
          source: "/Users/example/.openclaw/npm/projects/inline/dist/index.js",
        },
        install: {
          source: "npm",
          spec: "@inline-openclaw/inline@0.0.70",
          installPath: "/Users/example/.openclaw/npm/projects/inline",
          version: "0.0.70",
          resolvedVersion: "0.0.70",
          resolvedAt: "2026-09-15T21:04:29.571Z",
          installedAt: "2026-09-15T21:04:31.130Z",
        },
      },
    })

    const text = await runVersionCommand(pluginApi)

    expect(text).toContain("Plugin version: 0.0.70")
    expect(text).toContain("Install source: npm")
    expect(text).toContain("Last install/update: 2026-09-15T21:04:31.130Z")
    expect(text).toContain("Resolved at: 2026-09-15T21:04:29.571Z")
    expect(text).not.toContain("@inline-openclaw/inline")
    expect(text).not.toContain("/Users/example")
  })

  it("falls back to saved installation metadata when Gateway inspection is restricted", async () => {
    const pluginApi = api({
      request: async () => {
        throw new Error("Gateway request unavailable")
      },
    })

    const text = await runVersionCommand(pluginApi)

    expect(text).toContain("Install source: clawhub")
    expect(text).toContain("Last install/update: 2026-09-03T02:45:00.000Z")
  })

  it("sanitizes saved fallback metadata when Gateway inspection is restricted", async () => {
    const pluginApi = api({
      version: "0.0.70",
      config: {
        plugins: {
          installs: {
            inline: {
              source: "/Users/example/private/plugin.tgz",
              version: "0.0.70\nprivate-path",
              resolvedVersion: "@inline-openclaw/inline@0.0.70",
              resolvedAt: "not-a-timestamp",
              installedAt: "also-not-a-timestamp",
            },
          },
        },
      },
      request: async () => {
        throw new Error("Gateway request unavailable")
      },
    })

    const text = await runVersionCommand(pluginApi)

    expect(text).toContain("Plugin version: 0.0.70")
    expect(text).toContain("Install source: unavailable")
    expect(text).toContain("Last install/update: unavailable")
    expect(text).not.toContain("/Users/example")
    expect(text).not.toContain("private-path")
    expect(text).not.toContain("@inline-openclaw/inline")
  })

  it("reports the archive install shape returned by supported OpenClaw hosts", async () => {
    const pluginApi = api({
      version: "0.0.70",
      config: {},
      inspection: {
        plugin: {
          version: "0.0.70",
          source: "/Users/example/.openclaw/extensions/inline/dist/index.js",
        },
        install: {
          source: "archive",
          sourcePath: "/Users/example/inline-openclaw-inline-0.0.70.tgz",
          installPath: "/Users/example/.openclaw/extensions/inline",
          version: "0.0.70",
          installedAt: "2026-09-16T13:57:52.933Z",
        },
      },
    })

    const text = await runVersionCommand(pluginApi)

    expect(text).toContain("Plugin version: 0.0.70")
    expect(text).toContain("Install source: archive")
    expect(text).toContain("Last install/update: 2026-09-16T13:57:52.933Z")
    expect(text).not.toContain("inline-openclaw-inline-0.0.70.tgz")
    expect(text).not.toContain("/Users/example")
  })

  it("bounds a stalled Gateway inspection and retains honest unavailable fallbacks", async () => {
    vi.useFakeTimers()
    try {
      const pluginApi = api({
        config: {},
        request: () => new Promise(() => {}),
      })

      const result = runVersionCommand(pluginApi)
      await vi.advanceTimersByTimeAsync(2_000)

      await expect(result).resolves.toContain("Install source: unavailable")
      await expect(result).resolves.toContain("Last install/update: unavailable")
    } finally {
      vi.useRealTimers()
    }
  })

  it("forces a full catalog republish for an authorized sender", async () => {
    const commands = createInlineMaintenanceCommands(api())
    const sync = commands[0]!

    await expect(sync.handler({
      isAuthorizedSender: true,
      args: "",
    } as never)).resolves.toEqual({
      text: "Inline catalogs synced. Commands: 1/1 accounts. Skills: 1/1 accounts. Open or reopen the Skilled Agent editor in Inline to load the updated catalog.",
    })
    expect(syncInlineCatalogs).toHaveBeenCalledWith(expect.objectContaining({ reason: "manual" }))
  })
})
