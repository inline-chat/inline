import { describe, expect, it } from "bun:test"
import { createServer } from "node:http"
import { fetchBinary, fetchWithRedirects, readResponseText, readResponseTextPrefix } from "./network.js"
import { pinnedRequest } from "./pinnedRequest.js"
import type { FetchWithRedirectsOptions } from "./network.js"

const options = (overrides: Partial<FetchWithRedirectsOptions> = {}): FetchWithRedirectsOptions => ({
  lookup: async () => [{ address: "93.184.216.34", family: 4 }],
  fetchImpl: async () => new Response("ok"),
  timeoutMs: 200, maxRedirects: 3, userAgent: "test", accept: "text/html", ...overrides,
})

describe("preview network boundaries", () => {
  it("rejects unsupported upstream HTTP statuses without an uncaught callback error", async () => {
    const server = createServer((_request, response) => {
      response.writeHead(700)
      response.end("synthetic invalid response")
    })
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject)
      server.listen(0, "127.0.0.1", resolve)
    })
    try {
      const address = server.address()
      if (!address || typeof address === "string") throw new Error("No test address")
      await expect(pinnedRequest(
        new URL(`http://unresolvable-preview.invalid:${address.port}/`),
        { address: "127.0.0.1", family: 4 },
        { signal: AbortSignal.timeout(2_000) },
      )).rejects.toThrow("Unsupported preview response status")
    } finally {
      server.closeAllConnections()
      await new Promise<void>((resolve) => server.close(() => resolve()))
    }
  })

  it.each([{ address: "127.0.0.1", family: 4 }, { address: "::1", family: 6 }])("pins the selected $address and keeps the original Host without resolving it", async (selected) => {
    const server = createServer((request, response) => { response.end(request.headers.host) })
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(0, selected.address, resolve) })
    try {
      const address = server.address()
      if (!address || typeof address === "string") throw new Error("No test address")
      const url = new URL(`http://unresolvable-preview.invalid:${address.port}/`)
      const response = await pinnedRequest(url, selected, { signal: AbortSignal.timeout(2_000) })
      expect(await response.text()).toBe(url.host)
    } finally {
      server.closeAllConnections()
      await new Promise<void>((resolve) => server.close(() => resolve()))
    }
  })

  it("cancels redirects and rejects a destination that resolves to an internal address", async () => {
    let cancelled = false
    let requests = 0
    await expect(fetchWithRedirects("https://public.test/", options({
      lookup: async (host) => [{ address: host === "public.test" ? "93.184.216.34" : "127.0.0.1", family: 4 }],
      fetchImpl: async () => {
        requests++
        return new Response(new ReadableStream({ cancel() { cancelled = true } }), {
          status: 302, headers: { location: "https://internal.test/" },
        })
      },
    }))).rejects.toMatchObject({ code: "blocked_ip" })
    expect(requests).toBe(1)
    expect(cancelled).toBe(true)
  })

  it("bounds DNS and body stalls even when a supplied transport ignores AbortSignal", async () => {
    await expect(fetchWithRedirects("https://public.test/", options({
      timeoutMs: 20, lookup: () => new Promise(() => {}),
    }))).rejects.toMatchObject({ code: "timeout" })
    let cancelled = false
    const { response } = await fetchWithRedirects("https://public.test/", options({
      timeoutMs: 20,
      fetchImpl: async () => new Response(new ReadableStream({ cancel() { cancelled = true } })),
    }))
    await expect(readResponseText(response, 1_000)).rejects.toMatchObject({ code: "timeout" })
    expect(cancelled).toBe(true)
  })

  it("cancels bodies rejected by content type and exact-size prefix reads", async () => {
    let cancelled = 0
    const fetchImpl = async () => new Response(new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(new TextEncoder().encode("1234")) },
      cancel() { cancelled++ },
    }), { headers: { "content-type": "text/html" } })
    expect(await fetchBinary("https://public.test/", { ...options(), fetchImpl })).toBeNull()
    const { response } = await fetchWithRedirects("https://public.test/", options({ fetchImpl }))
    expect(await readResponseTextPrefix(response, 4)).toBe("1234")
    expect(cancelled).toBe(2)
  })
})
