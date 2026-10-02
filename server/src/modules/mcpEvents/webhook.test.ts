import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { execFileSync } from "node:child_process"
import { mkdtempSync, readFileSync } from "node:fs"
import { createServer, request as httpsRequest, type Server } from "node:https"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { signature } from "./crypto"
import { isPublicAddress, callbackUrl, makeCallbackTransport, resolveCallback, signedHeaders, verifyCallback, MAX_EVENT_BYTES } from "./webhook"

const secret = `whsec_${Buffer.alloc(32, 7).toString("base64")}`

describe("public callback destinations", () => {
  test("rejects all local/reserved IPv4 and mapped IPv6 forms", async () => {
    for (const address of ["0.0.0.0", "10.1.2.3", "127.0.0.1", "169.254.169.254", "172.31.0.1", "192.168.1.1", "100.64.0.1", "198.18.0.1", "192.0.2.1", "203.0.113.1", "255.255.255.255", "::", "::1", "fc00::1", "fe80::1", "ff02::1", "::ffff:7f00:1", "::ffff:127.0.0.1", "2001:db8::1", "2002:7f00:1::", "64:ff9b::7f00:1"]) expect(isPublicAddress(address)).toBe(false)
    for (const address of ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111", "2001:4860:4860::8888"]) expect(isPublicAddress(address)).toBe(true)
    await expect(resolveCallback("https://127.0.0.1/")).rejects.toThrow()
    await expect(resolveCallback("https://[::ffff:7f00:1]/")).rejects.toThrow()
  })
  test("rejects non-HTTPS, credentials, fragments and unsafe ports", () => {
    for (const value of ["http://receiver.test/", "https://user:pass@receiver.test/", "https://receiver.test/#fragment", "https://receiver.test:25/", "not a url"]) expect(() => callbackUrl(value)).toThrow()
  })
})

describe("actual HTTPS callback delivery", () => {
  let server: Server
  let port: number
  let certificate: string
  let requestCount = 0
  const requests: { body: string; headers: Record<string, string | string[] | undefined>; path: string }[] = []
  beforeAll(async () => {
    // Synthetic keys only, in a fresh OS temporary directory. Linux subprocess
    // pipes cannot reliably be reopened by OpenSSL through /dev/stdout.
    const directory = mkdtempSync(join(tmpdir(), "inline-mcp-events-tls-"))
    const keyPath = join(directory, "key.pem")
    const certificatePath = join(directory, "certificate.pem")
    execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=receiver.test", "-addext", "subjectAltName=DNS:receiver.test", "-days", "1", "-keyout", keyPath, "-out", certificatePath], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] })
    const key = readFileSync(keyPath, "utf8")
    certificate = readFileSync(certificatePath, "utf8")
    server = createServer({ key, cert: certificate }, (request, response) => {
      requestCount += 1
      let body = ""
      request.setEncoding("utf8")
      request.on("data", (part: string) => { body += part })
      request.on("end", () => {
        requests.push({ body, headers: request.headers, path: request.url ?? "" })
        if (request.url === "/redirect") { response.writeHead(302, { location: `https://127.0.0.1:${port}/forbidden` }); response.end(); return }
        if (request.url === "/large") { response.end("x".repeat(5000)); return }
        if (request.url === "/hanging-receipt") { response.writeHead(200); response.flushHeaders(); response.write("partial"); return }
        const input = JSON.parse(body) as { challenge?: string }
        response.setHeader("content-type", "application/json")
        response.end(JSON.stringify({ challenge: input.challenge }))
      })
    })
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
    const address = server.address()
    if (!address || typeof address === "string") throw new Error("Test listener has no TCP address")
    port = address.port
  })
  afterAll(async () => {
    if (server) await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()))
  })
  const transport = () => makeCallbackTransport({
    resolve: async (raw) => ({ url: new URL(`https://receiver.test:${port}${new URL(raw).pathname}`), address: "127.0.0.1", family: 4 }),
    request: (url, options, callback) => httpsRequest(url, { ...options, ca: certificate }, callback),
  })
  test("sends verification over a pinned TLS socket with correct hostname and exact signature", async () => {
    let authorityChecks = 0
    await verifyCallback({ id: "sub-1", url: "https://receiver.test/verify", secret, beforeConnect: async () => { authorityChecks += 1 } }, transport())
    const received = requests.at(-1)!
    expect(received.headers["x-mcp-subscription-id"]).toBe("sub-1")
    expect(received.headers["webhook-signature"]).toBe(signature(secret, String(received.headers["webhook-id"]), Number(received.headers["webhook-timestamp"]), received.body))
    expect(authorityChecks).toBe(1)
  })
  test("never follows a redirect and rejects oversized challenge responses", async () => {
    const count = requestCount
    await expect(verifyCallback({ id: "sub-1", url: "https://receiver.test/redirect", secret }, transport())).rejects.toThrow()
    expect(requestCount).toBe(count + 1)
    expect(requests.at(-1)?.path).toBe("/redirect")
    await expect(verifyCallback({ id: "sub-1", url: "https://receiver.test/large", secret }, transport())).rejects.toThrow()
  })
  test("authority failure after DNS resolution prevents opening the socket", async () => {
    const count = requestCount
    await expect(verifyCallback({ id: "sub-1", url: "https://receiver.test/verify", secret, beforeConnect: async () => { throw new Error("revoked") } }, transport())).rejects.toThrow()
    expect(requestCount).toBe(count)
  })
  test("occurrence receipt is any 2xx headers even with oversized or hanging response body", async () => {
    for (const path of ["/large", "/hanging-receipt"]) {
      const body = '{"eventId":"evt-receipt"}'
      const response = await transport()({ url: `https://receiver.test${path}`, body, headers: signedHeaders("sub-1", "evt-receipt", body, secret) })
      expect(response).toEqual({ status: 200, body: "" })
    }
  })
  test("IP pinning preserves strict verification of the original TLS hostname", async () => {
    const wrongHostname = makeCallbackTransport({
      resolve: async () => ({ url: new URL(`https://wrong-receiver.test:${port}/verify`), address: "127.0.0.1", family: 4 }),
      request: (url, options, callback) => httpsRequest(url, { ...options, ca: certificate }, callback),
    })
    await expect(verifyCallback({ id: "sub-1", url: "https://wrong-receiver.test/verify", secret }, wrongHostname)).rejects.toThrow()
  })
  test("bounds event bytes and emits both signatures only during caller's rotation window", async () => {
    const previous = `whsec_${Buffer.alloc(32, 8).toString("base64")}`
    const body = '{"eventId":"evt-1"}'
    const headers = signedHeaders("sub-1", "evt-1", body, secret, previous)
    expect(headers["webhook-signature"]?.split(" ")).toEqual([signature(secret, "evt-1", Number(headers["webhook-timestamp"]), body), signature(previous, "evt-1", Number(headers["webhook-timestamp"]), body)])
    await expect(transport()({ url: "https://receiver.test/verify", body: "x".repeat(MAX_EVENT_BYTES + 1), headers })).rejects.toThrow()
  })
})
