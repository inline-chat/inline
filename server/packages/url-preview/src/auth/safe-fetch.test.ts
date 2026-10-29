import { describe, expect, it } from "bun:test"
import { fetchProviderJson } from "./safe-fetch.js"

describe("authenticated preview deadlines", () => {
  it("cancels a provider body that stalls after headers", async () => {
    let cancelled = false
    await expect(fetchProviderJson("https://api.notion.com/v1/pages/page", {
      allowedHosts: ["api.notion.com"], timeoutMs: 20,
      fetchImpl: async () => new Response(new ReadableStream({ cancel() { cancelled = true } })),
    })).rejects.toMatchObject({ code: "timeout" })
    expect(cancelled).toBe(true)
  })

  it("bounds a supplied provider transport that ignores abort", async () => {
    await expect(fetchProviderJson("https://api.notion.com/v1/pages/page", {
      allowedHosts: ["api.notion.com"], timeoutMs: 20,
      fetchImpl: async () => new Promise<Response>(() => undefined),
    })).rejects.toMatchObject({ code: "timeout" })
  })

  it("cancels an unauthorized redirect before forwarding credentials", async () => {
    let requests = 0
    let cancelled = false
    await expect(fetchProviderJson("https://api.notion.com/v1/pages/page", {
      allowedHosts: ["api.notion.com"], headers: { Authorization: "Bearer synthetic-test-only" },
      fetchImpl: async () => {
        requests++
        return new Response(new ReadableStream({ cancel() { cancelled = true } }), {
          status: 302, headers: { location: "https://other.example/" },
        })
      },
    })).rejects.toMatchObject({ code: "blocked_host" })
    expect(requests).toBe(1)
    expect(cancelled).toBe(true)
  })
})
