import { expect, test } from "bun:test"
import { generateKeyPairSync } from "node:crypto"
import { Effect, Layer } from "effect"
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/unstable/http"
import { startCoreProductionServer } from "./productionHost"
import { makeIngressPolicy, ORIGIN_SECRET_HEADER, PROXY_SECRET_HEADER } from "./ingress"
import { makeHttpKernelMiddlewareLayer } from "./middleware"

// The server's DOM types mask Bun's documented client-header overload.
const BunSocket = WebSocket as unknown as new (url: string, options: Bun.WebSocketOptions) => WebSocket

for (const [mode, proof] of [
  ["cloudflare", "cloudflare"],
  ["cloudflare-or-proxy", "cloudflare"],
  ["cloudflare-or-proxy", "proxy"],
] as const) {
test(`the ${mode} listener with ${proof} proof gates HTTP, verification and both WebSocket upgrades`, async () => {
  const secret = "ab".repeat(32)
  const proxySecret = "cd".repeat(32)
  const clientIpHeader = mode === "cloudflare" ? "cf-connecting-ip" : "x-real-ip"
  const proofHeader = proof === "cloudflare" ? ORIGIN_SECRET_HEADER : PROXY_SECRET_HEADER
  const suppliedIpHeader = proof === "cloudflare" ? "cf-connecting-ip" : "x-real-ip"
  const ingressPolicy = makeIngressPolicy({
    INLINE_INGRESS_MODE: mode,
    INLINE_INGRESS_HOST: "api.example.test",
    INLINE_ORIGIN_SECRET: secret,
    ...(mode === "cloudflare-or-proxy" ? { INLINE_PROXY_SECRET: proxySecret } : {}),
  }, clientIpHeader)!
  let ready = false
  let handled = 0
  const application = Layer.effectDiscard(HttpRouter.HttpRouter.use((router) =>
    Effect.all([
      router.add("GET", "/readyz", Effect.sync(() =>
        HttpServerResponse.text(ready ? "ready" : "not ready", { status: ready ? 200 : 503 }))),
      router.add("POST", "/echo", HttpServerRequest.HttpServerRequest.use((request) =>
        request.text.pipe(Effect.map((body) => {
          handled++
          return HttpServerResponse.jsonUnsafe({
            body,
            ip: request.headers[clientIpHeader],
            secretPresent: ORIGIN_SECRET_HEADER in request.headers || PROXY_SECRET_HEADER in request.headers,
            conflictingIpPresent: (mode === "cloudflare" ? "x-real-ip" : "cf-connecting-ip") in request.headers,
          })
        })))),
    ]))).pipe(Layer.provideMerge(makeHttpKernelMiddlewareLayer({ clientIpHeader, isProduction: false })))
  const ring = { activeId: "test", keys: new Map([["test", new Uint8Array(32).fill(1)]]) }
  const rsaPrivateKeysJson = JSON.stringify(Array.from({ length: 2 }, () => ({
    privateKeyPem: generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey.export({ type: "pkcs8", format: "pem" }),
  })))
  const handle = await startCoreProductionServer({
    application,
    hostname: "127.0.0.1",
    ingressPolicy,
    clientIpHeader,
    markShuttingDown: () => {},
    startClusterServices: false,
    inlineProtocolConfiguration: {
      enabled: true, requireCanonicalPublicRing: false, rsaPrivateKeysJson,
      authKeyKekRing: ring, authCodePepperRing: ring, encryptReplayResults: false,
    },
  })
  const base = `http://127.0.0.1:${handle.port}`
  const headers = {
    host: "api.example.test",
    [proofHeader]: proof === "cloudflare" ? secret : proxySecret,
    "cf-connecting-ip": "192.0.2.1",
    "x-real-ip": "192.0.2.2",
    [suppliedIpHeader]: "2001:db8::42",
  }
  try {
    expect((await fetch(`${base}/echo`, { method: "POST", body: "rejected" })).status).toBe(403)
    expect(handled).toBe(0)
    const accepted = await fetch(`${base}/echo`, { method: "POST", body: "preserved body", headers })
    expect(await accepted.json()).toEqual({ body: "preserved body", ip: "2001:db8::42", secretPresent: false, conflictingIpPresent: false })
    expect(handled).toBe(1)
    expect((await fetch(`${base}/readyz`)).status).toBe(503)
    ready = true
    expect((await fetch(`${base}/readyz`)).status).toBe(200)
    const head = await fetch(`${base}/readyz`, { method: "HEAD" })
    expect(head.status).toBe(200)
    expect(await head.text()).toBe("")
    expect((await fetch(`${base}/readyz?bypass=1`)).status).toBe(403)
    expect((await fetch(`${base}/.well-known/inline-protocol`)).status).toBe(403)
    expect((await fetch(`${base}/.well-known/inline-protocol`, { headers })).status).toBe(200)

    for (const path of ["/realtime", "/realtime/v3"]) {
      const denied = await fetch(`${base}${path}`, { headers: {
        ...headers, [proofHeader]: "wrong", upgrade: "websocket", connection: "Upgrade",
        "sec-websocket-version": "13", "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
      } })
      expect(denied.status).toBe(403)
      const socket = new BunSocket(`${base.replace("http:", "ws:")}${path}`, { headers })
      try {
        await new Promise<void>((resolve, reject) => {
          socket.addEventListener("open", () => resolve(), { once: true })
          socket.addEventListener("error", () => reject(new Error("Local upgrade failed")), { once: true })
        })
        expect(socket.readyState).toBe(WebSocket.OPEN)
      } finally {
        const closed = new Promise<void>((resolve) => socket.addEventListener("close", () => resolve(), { once: true }))
        socket.close()
        await closed
      }
    }
  } finally {
    await handle.shutdown()
  }
}, 15_000)
}
