import { describe, expect, it, vi } from "vitest"
import type { OpenClawPluginApi, PluginRuntime } from "openclaw/plugin-sdk"
import { readFile } from "node:fs/promises"
import path from "node:path"

describe("plugin entry", () => {
  it("registers the channel, Inline message hook, and wires runtime", async () => {
    vi.resetModules()
    const syncInlineNativeCommands = vi.fn(async () => ({ attempted: 1, synced: 1, failed: 0 }))
    vi.doMock("./inline/bot-commands-sync.js", () => ({
      syncInlineNativeCommands,
    }))
    const pluginMod = await import("./index.ts")

    const runtime = { version: "test" } as unknown as PluginRuntime
    let registered = false
    const registeredToolNames: string[] = []
    const hooks = new Map<string, Function>()
    const api = {
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
      on: (hookName: string, handler: Function) => {
        hooks.set(hookName, handler)
      },
    } as unknown as OpenClawPluginApi

    pluginMod.default.register(api)

    expect(registered).toBe(true)
    const expectedToolNames = [
      "inline_members",
      "inline_update_profile",
      "inline_bot_commands",
      "inline_nudge",
      "inline_forward",
    ]
    expect(registeredToolNames).toEqual(expectedToolNames)
    const manifestPath = path.resolve(__dirname, "..", "openclaw.plugin.json")
    const rawManifest = await readFile(manifestPath, "utf8")
    const manifest = JSON.parse(rawManifest) as { contracts?: { tools?: unknown } }
    expect(manifest.contracts?.tools).toEqual(expectedToolNames)
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

    const gatewayStart = hooks.get("gateway_start")
    expect(gatewayStart).toBeTypeOf("function")
    await gatewayStart?.({ port: 24282 }, { port: 24282 })
    expect(syncInlineNativeCommands).toHaveBeenCalledWith(
      expect.objectContaining({
        cfg: api.config,
        logger: api.logger,
      }),
    )
  })
})
