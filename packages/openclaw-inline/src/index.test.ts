import { describe, expect, it, vi } from "vitest"
import type { OpenClawPluginApi, PluginRuntime } from "openclaw/plugin-sdk"

describe("plugin entry", () => {
  it("registers the channel and wires runtime", async () => {
    vi.resetModules()

    const pluginMod = await import("./index")
    const runtimeMod = await import("./runtime")

    const runtime = { version: "test" } as unknown as PluginRuntime
    let registered = false
    const api = {
      runtime,
      registerChannel: ({ plugin }) => {
        registered = true
        expect(plugin.id).toBe("inline")
      },
    } as unknown as OpenClawPluginApi

    pluginMod.default.register(api)

    expect(registered).toBe(true)
    expect(runtimeMod.getInlineRuntime()).toBe(runtime)
  })
})

