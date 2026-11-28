import { describe, expect, it, vi } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import {
  buildOpenClawDashboardLink,
  LOOPBACK_ONLY_TEXT,
  normalizeControlUiBasePath,
  OpenClawDashboardUnavailableError,
  type OpenClawDashboardDeps,
} from "./dashboard-link.js"

const deps = (overrides: Partial<OpenClawDashboardDeps> = {}): OpenClawDashboardDeps => ({
  issueBootstrapToken: async () => "one-time",
  resolvePublicOrigin: () => undefined,
  resolveTailnetHost: async () => null,
  resolvePort: () => 18789,
  hostLabel: () => "Mo's MacBook Pro",
  runCommand: async () => ({ code: 0, stdout: "" }),
  ...overrides,
})

const config = (gateway: Record<string, unknown> = {}) => ({ gateway }) as unknown as OpenClawConfig

describe("OpenClaw dashboard link", () => {
  it("falls back to loopback and says how to reach it from elsewhere", async () => {
    const link = await buildOpenClawDashboardLink(config(), deps())
    expect(link.url).toBe(
      "http://127.0.0.1:18789/#gatewayUrl=ws%3A%2F%2F127.0.0.1%3A18789&bootstrapToken=one-time",
    )
    expect(link.unreachableText).toBe(LOOPBACK_ONLY_TEXT)
    expect(link.hostLabel).toBe("Mo's MacBook Pro")
  })

  it("uses the Tailscale Serve host with the base path", async () => {
    const resolveTailnetHost = vi.fn(async () => "mo-mbp.tail1234.ts.net")
    const link = await buildOpenClawDashboardLink(
      config({ tailscale: { mode: "serve" }, controlUi: { basePath: "/openclaw/" } }),
      deps({ resolveTailnetHost }),
    )
    expect(link.url).toBe(
      "https://mo-mbp.tail1234.ts.net/openclaw/#gatewayUrl=wss%3A%2F%2Fmo-mbp.tail1234.ts.net%2Fopenclaw&bootstrapToken=one-time",
    )
    expect(link.unreachableText).toBeUndefined()
  })

  it("prefers an allowed HTTPS public origin", async () => {
    const link = await buildOpenClawDashboardLink(
      config({ controlUi: { allowedOrigins: ["https://claw.example.com"] } }),
      deps({ resolvePublicOrigin: () => "https://claw.example.com" }),
    )
    expect(link.url.startsWith("https://claw.example.com/#gatewayUrl=wss%3A%2F%2Fclaw.example.com&")).toBe(true)
  })

  it("ignores a public origin the Control UI doesn't allow", async () => {
    const link = await buildOpenClawDashboardLink(
      config({ controlUi: { allowedOrigins: ["https://other.example.com"] } }),
      deps({ resolvePublicOrigin: () => "https://claw.example.com" }),
    )
    expect(link.url.startsWith("http://127.0.0.1:18789/")).toBe(true)
  })

  it("explains a turned-off Control UI without minting a token", async () => {
    const issueBootstrapToken = vi.fn(async () => "never")
    await expect(
      buildOpenClawDashboardLink(config({ controlUi: { enabled: false } }), deps({ issueBootstrapToken })),
    ).rejects.toBeInstanceOf(OpenClawDashboardUnavailableError)
    expect(issueBootstrapToken).not.toHaveBeenCalled()
  })

  it("normalizes base paths", () => {
    expect(normalizeControlUiBasePath(undefined)).toBe("")
    expect(normalizeControlUiBasePath("/")).toBe("")
    expect(normalizeControlUiBasePath("ui//")).toBe("/ui")
  })
})
