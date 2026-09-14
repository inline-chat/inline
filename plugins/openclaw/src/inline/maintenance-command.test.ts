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

function api(): OpenClawPluginApi {
  return {
    id: "inline",
    version: "0.0.66",
    runtime: {
      version: "2026.8.2",
      gateway: {
        isAvailable: vi.fn(async () => true),
        request: vi.fn(async () => ({
          plugin: { version: "0.0.66" },
          source: { kind: "clawhub" },
        })),
      },
    } as unknown as PluginRuntime,
    config: {
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
