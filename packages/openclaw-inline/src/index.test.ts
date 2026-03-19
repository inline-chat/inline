import { describe, expect, it, vi } from "vitest"
import type { OpenClawPluginApi, PluginRuntime } from "openclaw/plugin-sdk"

describe("plugin entry", () => {
  it("registers the channel and wires runtime", async () => {
    vi.resetModules()
    const pluginMod = await import("./index.ts")

    const runtime = { version: "test" } as unknown as PluginRuntime
    let registered = false
    const registeredToolNames: string[] = []
    const api = {
      runtime,
      registerChannel: ({ plugin }) => {
        registered = true
        expect(plugin.id).toBe("inline")
      },
      registerTool: (_tool, opts) => {
        registeredToolNames.push(...(opts?.names ?? []))
      },
    } as unknown as OpenClawPluginApi

    pluginMod.default.register(api)

    expect(registered).toBe(true)
    expect(registeredToolNames).toEqual(["inline_members", "inline_update_profile", "inline_nudge", "inline_forward"])
  })
})
