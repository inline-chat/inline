import { describe, expect, it, vi } from "vitest"

describe("sdk-version", () => {
  it("reads and caches version from package.json", async () => {
    vi.resetModules()
    const readFileSync = vi.fn(() => JSON.stringify({ version: "9.8.7" }))
    vi.doMock("node:fs", () => ({ readFileSync }))

    const { getSdkVersion } = await import("./sdk-version.js")
    expect(getSdkVersion()).toBe("9.8.7")
    expect(getSdkVersion()).toBe("9.8.7")
    expect(readFileSync).toHaveBeenCalledTimes(1)
  })

  it("falls back to unknown when package.json cannot be parsed", async () => {
    vi.resetModules()
    const readFileSync = vi.fn(() => "{ invalid")
    vi.doMock("node:fs", () => ({ readFileSync }))

    const { getSdkVersion } = await import("./sdk-version.js")
    expect(getSdkVersion()).toBe("unknown")
  })
})
