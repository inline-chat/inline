import { describe, expect, it, vi } from "vitest"
import type { OpenClawPluginApi, PluginRuntime } from "openclaw/plugin-sdk"

describe("plugin entry", () => {
  it("exposes a native-style bundled runtime entry with split loaders", async () => {
    vi.resetModules()
    const { default: entry } = await import("./index.ts")

    expect(entry.kind).toBe("bundled-channel-entry")
    expect(entry.id).toBe("inline")
    expect(entry.features).toEqual({ accountInspect: true })
    expect(entry.loadChannelPlugin().id).toBe("inline")
    expect(entry.loadChannelSecrets?.()?.secretTargetRegistryEntries.map((item) => item.id)).toEqual([
      "channels.inline.accounts.*.token",
      "channels.inline.token",
    ])

    const inspect = entry.loadChannelAccountInspector?.()
    expect(
      inspect?.({
        channels: {
          inline: {
            token: "test-token",
          },
        },
      }),
    ).toEqual(
      expect.objectContaining({
        accountId: "default",
        configured: true,
        tokenSource: "config",
        tokenStatus: "available",
      }),
    )
  }, 60_000)

  it("keeps the setup entry split with secret metadata", async () => {
    vi.resetModules()
    const { default: setupEntry } = await import("./setup-entry")

    expect(setupEntry.kind).toBe("bundled-channel-setup-entry")
    const setupPlugin = setupEntry.loadSetupPlugin()
    const setupSecrets = setupEntry.loadSetupSecrets?.()

    expect(setupPlugin.id).toBe("inline")
    expect(setupPlugin.secrets?.secretTargetRegistryEntries.map((entry) => entry.id)).toEqual([
      "channels.inline.accounts.*.token",
      "channels.inline.token",
    ])
    expect(setupSecrets?.secretTargetRegistryEntries.map((entry) => entry.id)).toEqual([
      "channels.inline.accounts.*.token",
      "channels.inline.token",
    ])
  })

  it("registers the channel, full-runtime hooks, and wires runtime", async () => {
    vi.resetModules()
    const { default: entry } = await import("./index.ts")

    const runtime = { version: "test" } as unknown as PluginRuntime
    let registered = false
    const registeredToolNames: string[] = []
    const registeredCommandNames: string[] = []
    const hooks = new Map<string, Function>()
    const api = {
      registrationMode: "full",
      runtime,
      config: {
        channels: {
          inline: {
            systemPrompt: "Keep replies short.",
          },
        },
      },
      logger: {
        info: vi.fn(),
        warn: vi.fn(),
        error: vi.fn(),
      },
      registerChannel: ({ plugin }) => {
        registered = true
        expect(plugin.id).toBe("inline")
      },
      registerTool: (_tool, opts) => {
        registeredToolNames.push(...(opts?.names ?? []))
      },
      registerCommand: (command) => {
        registeredCommandNames.push(command.name)
      },
      on: (hookName: string, handler: Function) => {
        hooks.set(hookName, handler)
      },
    } as unknown as OpenClawPluginApi

    entry.register(api)

    expect(registered).toBe(true)
    expect(entry.setChannelRuntime).toBeTypeOf("function")
    expect(registeredToolNames).toEqual([
      "inline_members",
      "inline_update_profile",
      "inline_bot_commands",
      "inline_nudge",
      "inline_forward",
      "inline_parent_context",
    ])
    expect(registeredCommandNames).toEqual(["threadreply"])
    expect(hooks.has("message_sending")).toBe(true)
    expect(hooks.has("gateway_start")).toBe(true)

    const messageSending = hooks.get("message_sending")
    expect(messageSending).toBeTypeOf("function")
    expect(
      messageSending?.(
        { to: "inline:42", content: "See `https://example.com/docs`" },
        { channelId: "inline" },
      ),
    ).toEqual({ content: "See https://example.com/docs" })
    expect(
      messageSending?.({ to: "inline:42", content: "Run `bun test`" }, { channelId: "inline" }),
    ).toBeUndefined()
    expect(
      messageSending?.(
        {
          to: "inline:42",
          content: [
            "OpenClaw runtime context for the immediately preceding user message.",
            "This context is runtime-generated, not user-authored. Keep internal details private.",
            "",
            "Read HEARTBEAT.md if it exists. If nothing needs attention, reply HEARTBEAT_OK.",
          ].join("\n"),
        },
        { channelId: "inline" },
      ),
    ).toEqual({
      content: "",
      cancel: true,
      cancelReason: "suppressed_internal_context",
    })

    const gatewayStart = hooks.get("gateway_start")
    expect(gatewayStart).toBeTypeOf("function")
    await gatewayStart?.({ port: 24282 }, { port: 24282 })
  })
})
