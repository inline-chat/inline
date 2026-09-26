import { describe, expect, test } from "bun:test"
import { makeIngressPolicy, ORIGIN_SECRET_HEADER, PROXY_SECRET_HEADER } from "./ingress"
import { getIp } from "../../utils/ip"

const secret = "ab".repeat(32)
const configuration = {
  INLINE_INGRESS_MODE: "cloudflare",
  INLINE_INGRESS_HOST: "api.example.test",
  INLINE_ORIGIN_SECRET: secret,
}
const policy = makeIngressPolicy(configuration, "cf-connecting-ip")!
const request = (headers: Record<string, string> = {}, path = "/v1/test", method = "GET") =>
  new Request(`http://api.example.test${path}`, {
    method,
    headers: {
      host: "api.example.test",
      [ORIGIN_SECRET_HEADER]: secret,
      "cf-connecting-ip": "198.51.100.42",
      ...headers,
    },
  })

describe("origin ingress configuration", () => {
  test("leaves the existing deployment unchanged unless configured", () => {
    expect(makeIngressPolicy({}, "x-real-ip")).toBeUndefined()
    expect(makeIngressPolicy({}, "direct")).toBeUndefined()
  })

  test("fails closed on partial configuration and incompatible trust modes", () => {
    for (const env of [
      { INLINE_ORIGIN_SECRET: secret },
      { ...configuration, INLINE_INGRESS_MODE: "disabled" },
      { ...configuration, INLINE_ORIGIN_SECRET: "too-short" },
      { ...configuration, INLINE_INGRESS_HOST: "*.example.test" },
      { ...configuration, INLINE_INGRESS_HOST: "https://api.example.test" },
      { ...configuration, INLINE_INGRESS_HOST: "api.example.test:443" },
    ]) {
      expect(() => makeIngressPolicy(env, "cf-connecting-ip")).toThrow()
      try { makeIngressPolicy(env, "cf-connecting-ip") }
      catch (error) { expect(String(error)).not.toContain(secret) }
    }
    expect(() => makeIngressPolicy(configuration, "x-real-ip")).toThrow()
    expect(() => makeIngressPolicy(configuration, "direct")).toThrow()
  })
})

describe("Cloudflare or trusted origin proxy", () => {
  const proxySecret = "cd".repeat(32)
  const proxyConfiguration = {
    ...configuration,
    INLINE_INGRESS_MODE: "cloudflare-or-proxy",
    INLINE_PROXY_SECRET: proxySecret,
  }
  const proxyPolicy = makeIngressPolicy(proxyConfiguration, "x-real-ip")!

  test("requires a complete, distinct proxy credential and the canonical IP mode", () => {
    for (const env of [
      { INLINE_PROXY_SECRET: proxySecret },
      { ...configuration, INLINE_PROXY_SECRET: proxySecret },
      { ...proxyConfiguration, INLINE_PROXY_SECRET: undefined },
      { ...proxyConfiguration, INLINE_PROXY_SECRET: secret },
      { ...proxyConfiguration, INLINE_PROXY_SECRET: "invalid" },
    ]) expect(() => makeIngressPolicy(env, "x-real-ip")).toThrow()
    expect(() => makeIngressPolicy(proxyConfiguration, "cf-connecting-ip")).toThrow()
    expect(() => makeIngressPolicy(proxyConfiguration, "direct")).toThrow()
  })

  test("prefers authenticated Cloudflare identity and otherwise uses only the authenticated proxy identity", () => {
    for (const originSecret of [secret, "forged", ""]) {
      const incoming = request({
        [ORIGIN_SECRET_HEADER]: originSecret,
        [PROXY_SECRET_HEADER]: proxySecret,
        "cf-connecting-ip": "198.51.100.42",
        "x-real-ip": "2001:db8::42",
        "x-forwarded-for": "192.0.2.1",
      })
      expect(proxyPolicy(incoming)).toBeUndefined()
      expect(getIp(incoming)).toBe(originSecret === secret ? "198.51.100.42" : "2001:db8::42")
      for (const header of [ORIGIN_SECRET_HEADER, PROXY_SECRET_HEADER, "cf-connecting-ip", "x-forwarded-for"]) {
        expect(incoming.headers.has(header)).toBe(false)
      }
    }
  })

  test("rejects forged, incomplete, ambiguous and wrong-host proxy requests", () => {
    const cases: Record<string, string>[] = [
      { [PROXY_SECRET_HEADER]: "forged" },
      { [PROXY_SECRET_HEADER]: `${proxySecret}, ${proxySecret}` },
      { "x-real-ip": "" },
      { "x-real-ip": "198.51.100.42, 192.0.2.1" },
      { "x-real-ip": "fe80::1%eth0" },
      { "x-real-ip": "not-an-ip" },
      { host: "other.example.test" },
    ]
    for (const overrides of cases) {
      const incoming = request({
        [ORIGIN_SECRET_HEADER]: "forged", [PROXY_SECRET_HEADER]: proxySecret,
        "x-real-ip": "198.51.100.42", ...overrides,
      })
      expect(proxyPolicy(incoming)?.status).toBe(403)
      for (const header of [ORIGIN_SECRET_HEADER, PROXY_SECRET_HEADER, "cf-connecting-ip", "x-real-ip"]) {
        expect(incoming.headers.has(header)).toBe(false)
      }
    }
  })

  test("strips both credentials on the readiness exception", () => {
    const incoming = request({ [PROXY_SECRET_HEADER]: proxySecret }, "/readyz")
    expect(proxyPolicy(incoming)).toBeUndefined()
    expect(incoming.headers.has(ORIGIN_SECRET_HEADER)).toBe(false)
    expect(incoming.headers.has(PROXY_SECRET_HEADER)).toBe(false)
    expect(getIp(incoming)).toBeUndefined()
  })
})

describe("origin ingress authorization", () => {
  test("rejects forged origins without reflecting or retaining credentials", () => {
    for (const overrides of [
      { [ORIGIN_SECRET_HEADER]: "" },
      { [ORIGIN_SECRET_HEADER]: "cd".repeat(32) },
      { [ORIGIN_SECRET_HEADER]: "é".repeat(64) },
      { [ORIGIN_SECRET_HEADER]: `${secret}, ${secret}` },
      { host: "other.example.test" },
      { host: "api.example.test:443" },
      { "cf-connecting-ip": "" },
      { "cf-connecting-ip": "127.0.0.1, 198.51.100.1" },
      { "cf-connecting-ip": "not-an-ip" },
      { "cf-connecting-ip": "fe80::1%eth0" },
    ] as Record<string, string>[]) {
      const incoming = request(overrides)
      expect(policy(incoming)?.status).toBe(403)
      expect(incoming.headers.has(ORIGIN_SECRET_HEADER)).toBe(false)
      expect(incoming.headers.has("cf-connecting-ip")).toBe(false)
    }
  })

  test("normalizes all IP consumers to the authenticated IPv4 or IPv6 address", () => {
    for (const ip of ["198.51.100.42", "2001:db8::42"]) {
      const incoming = request({
        "cf-connecting-ip": ip,
        "x-real-ip": "192.0.2.1",
        "x-forwarded-for": "192.0.2.2",
        "x-forwarded": "192.0.2.3",
        "forwarded": "for=192.0.2.4",
        "fly-client-ip": "192.0.2.5",
        "true-client-ip": "192.0.2.6",
        authorization: "Bearer application-credential",
      })
      expect(policy(incoming)).toBeUndefined()
      expect(getIp(incoming)).toBe(ip)
      expect(incoming.headers.get("cf-connecting-ip")).toBe(ip)
      expect(incoming.headers.get("authorization")).toBe("Bearer application-credential")
      for (const header of [ORIGIN_SECRET_HEADER, "x-real-ip", "x-forwarded-for", "x-forwarded", "forwarded", "fly-client-ip", "true-client-ip"]) {
        expect(incoming.headers.has(header)).toBe(false)
      }
    }
  })

  test("allows only an ordinary GET or HEAD readiness probe without origin authentication", () => {
    for (const method of ["GET", "HEAD"]) {
      const incoming = request({ [ORIGIN_SECRET_HEADER]: "", host: "internal" }, "/readyz", method)
      expect(policy(incoming)).toBeUndefined()
      expect(getIp(incoming)).toBeUndefined()
    }
    for (const [path, method, extra] of [
      ["/readyz?probe=1", "GET", {}],
      ["/readyz/", "GET", {}],
      ["/readyz", "POST", {}],
      ["/readyz", "GET", { upgrade: "websocket" }],
      ["/readyz", "GET", { "sec-websocket-key": "synthetic" }],
      ["/realtime", "GET", {}],
      ["/realtime/v3", "GET", {}],
      ["/.well-known/inline-protocol", "GET", {}],
    ] as const) {
      expect(policy(request({ [ORIGIN_SECRET_HEADER]: "", ...extra }, path, method))?.status).toBe(403)
    }
  })
})
