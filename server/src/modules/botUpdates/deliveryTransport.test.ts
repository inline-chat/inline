import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { execFileSync } from "node:child_process"
import { mkdtempSync, readFileSync } from "node:fs"
import { createServer, request as httpsRequest, type Server } from "node:https"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { makeBotWebhookTransport } from "./delivery"

describe("bot webhook HTTPS transport", () => {
  let server: Server
  let port: number
  let certificate: string
  const hosts: (string | undefined)[] = []

  beforeAll(async () => {
    // Synthetic keys only, in a fresh OS temporary directory.
    const directory = mkdtempSync(join(tmpdir(), "inline-bot-webhook-tls-"))
    const keyPath = join(directory, "key.pem")
    const certificatePath = join(directory, "certificate.pem")
    execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=receiver.test", "-addext", "subjectAltName=DNS:receiver.test", "-days", "1", "-keyout", keyPath, "-out", certificatePath], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] })
    const key = readFileSync(keyPath, "utf8")
    certificate = readFileSync(certificatePath, "utf8")
    server = createServer({ key, cert: certificate }, (request, response) => {
      hosts.push(request.headers.host)
      request.resume()
      request.on("end", () => {
        if (request.url === "/large") { response.end("x".repeat(64 * 1024)); return }
        if (request.url === "/hanging-body") { response.writeHead(200); response.flushHeaders(); response.write("partial"); return }
        if (request.url === "/silent") return
        if (request.url === "/busy") { response.writeHead(429, { "retry-after": "7" }); response.end(); return }
        response.end("ok")
      })
    })
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
    const address = server.address()
    if (!address || typeof address === "string") throw new Error("Test listener has no TCP address")
    port = address.port
  })

  afterAll(async () => {
    server.closeAllConnections()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  })

  const transport = (timeoutMs = 2_000) => makeBotWebhookTransport({
    resolve: async (raw) => ({ url: new URL(`https://receiver.test:${port}${new URL(raw).pathname}`), address: "127.0.0.1", family: 4 }),
    request: (url, options, callback) => httpsRequest(url, { ...options, ca: certificate }, callback),
    timeoutMs,
  })
  const send = (path: string, timeoutMs?: number) => transport(timeoutMs)({
    rawUrl: `https://receiver.test${path}`,
    body: "{}",
    headers: { "content-type": "application/json" },
    beforeConnect: async () => true,
  })

  test("delivers over the pinned address with the original hostname for TLS and Host", async () => {
    expect(await send("/ok")).toEqual({ status: 200, retryAfter: undefined })
    expect(hosts.at(-1)).toBe(`receiver.test:${port}`)
  })

  test("settles at response headers for large and never-ending bodies", async () => {
    expect((await send("/large"))?.status).toBe(200)
    expect((await send("/hanging-body"))?.status).toBe(200)
  })

  test("surfaces Retry-After and rejects silent receivers at the absolute deadline", async () => {
    expect(await send("/busy")).toEqual({ status: 429, retryAfter: "7" })
    const started = Date.now()
    await expect(send("/silent", 300)).rejects.toThrow("timed out")
    expect(Date.now() - started).toBeLessThan(2_000)
  })

  test("does not connect when the claim is no longer current", async () => {
    const count = hosts.length
    const result = await transport()({ rawUrl: "https://receiver.test/ok", body: "{}", headers: {}, beforeConnect: async () => false })
    expect(result).toBeUndefined()
    expect(hosts.length).toBe(count)
  })
})
