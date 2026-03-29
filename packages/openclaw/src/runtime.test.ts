import { describe, expect, it, vi } from "vitest"
import type { PluginRuntime } from "openclaw/plugin-sdk"

describe("runtime", () => {
  it("throws before initialization", async () => {
    vi.resetModules()
    const mod = await import("./runtime")
    expect(() => mod.getInlineRuntime()).toThrow(/not initialized/i)
  })

  it("returns the last set runtime", async () => {
    vi.resetModules()
    const mod = await import("./runtime")
    const runtime = { version: "test" } as unknown as PluginRuntime
    mod.setInlineRuntime(runtime)
    expect(mod.getInlineRuntime()).toBe(runtime)
  })
})

