import { timingSafeEqual } from "node:crypto"
import { isIP } from "node:net"
import type { ClientIpMode } from "./middleware"

export const ORIGIN_SECRET_HEADER = "x-inline-origin-secret"
export const PROXY_SECRET_HEADER = "x-inline-proxy-secret"

/** Runs on the original Bun request, before HTTP middleware or any upgrade. */
export type IngressPolicy = (request: Request) => Response | undefined

const forwardedHeaders = [
  "cf-connecting-ip", "cf-connecting-ipv6", "true-client-ip",
  "x-real-ip", "x-forwarded-for", "x-forwarded", "forwarded",
  "fly-client-ip", "x-forwarded-host", "x-forwarded-proto", "x-forwarded-port",
] as const

export const makeIngressPolicy = (
  env: Readonly<Record<string, string | undefined>>,
  clientIpMode: ClientIpMode,
): IngressPolicy | undefined => {
  const mode = env["INLINE_INGRESS_MODE"]
  const host = env["INLINE_INGRESS_HOST"]
  const secret = env["INLINE_ORIGIN_SECRET"]
  const proxySecret = env["INLINE_PROXY_SECRET"]
  if (mode === undefined && host === undefined && secret === undefined && proxySecret === undefined) return undefined
  if (mode !== "cloudflare" && mode !== "cloudflare-or-proxy") {
    throw new Error("INLINE_INGRESS_MODE must be cloudflare or cloudflare-or-proxy when ingress configuration is present")
  }
  // One DNS hostname, without scheme, port, wildcard, or path. Never echo config.
  if (!host || host.length > 253 || !/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(host)) {
    throw new Error("INLINE_INGRESS_HOST must be a lowercase DNS hostname")
  }
  if (!secret || !/^[a-f0-9]{64}$/.test(secret)) {
    throw new Error("INLINE_ORIGIN_SECRET must contain 32 random bytes encoded as lowercase hex")
  }
  if (mode === "cloudflare-or-proxy") {
    if (!proxySecret || !/^[a-f0-9]{64}$/.test(proxySecret) || proxySecret === secret) {
      throw new Error("INLINE_PROXY_SECRET must contain 32 random bytes encoded as lowercase hex, distinct from INLINE_ORIGIN_SECRET")
    }
  } else if (proxySecret !== undefined) {
    throw new Error("INLINE_PROXY_SECRET requires INLINE_INGRESS_MODE=cloudflare-or-proxy")
  }
  const canonicalIpHeader = mode === "cloudflare" ? "cf-connecting-ip" : "x-real-ip"
  if (clientIpMode !== canonicalIpHeader) {
    throw new Error(`Configured ingress requires INLINE_TRUSTED_CLIENT_IP_HEADER=${canonicalIpHeader}`)
  }
  const expectedSecret = Buffer.from(secret, "ascii")
  const expectedProxySecret = proxySecret ? Buffer.from(proxySecret, "ascii") : undefined
  const validProof = (supplied: string | null, expected: Buffer | undefined, ip: string | null): ip is string =>
    Boolean(expected && supplied && /^[a-f0-9]{64}$/.test(supplied) &&
      timingSafeEqual(Buffer.from(supplied, "ascii"), expected) &&
      ip && isIP(ip) && !ip.includes("%"))

  return (request) => {
    const suppliedSecret = request.headers.get(ORIGIN_SECRET_HEADER)
    const suppliedProxySecret = request.headers.get(PROXY_SECRET_HEADER)
    const cfIp = request.headers.get("cf-connecting-ip")
    const proxyIp = request.headers.get("x-real-ip")
    // Strip credentials and competing proxy identities even on rejected requests.
    // Keep the original Request: Bun owns its body, peer address, and upgrade state.
    request.headers.delete(ORIGIN_SECRET_HEADER)
    request.headers.delete(PROXY_SECRET_HEADER)
    for (const header of forwardedHeaders) request.headers.delete(header)

    const url = new URL(request.url)
    if (
      (request.method === "GET" || request.method === "HEAD") &&
      url.pathname === "/readyz" && url.search === "" &&
      !request.headers.has("upgrade") &&
      !request.headers.has("sec-websocket-key")
    ) {
      // Fly's unauthenticated probe must still run the application's readiness
      // route, including database and shutdown checks. No synthetic success here.
      return undefined
    }

    // Cloudflare authenticates its client identity independently of the local
    // reverse proxy. Otherwise use only the proxy's authenticated peer identity.
    // The proxy must overwrite its secret and derive x-real-ip from the peer,
    // never from untrusted forwarding or PROXY-protocol headers.
    const clientIp = validProof(suppliedSecret, expectedSecret, cfIp) ? cfIp
      : validProof(suppliedProxySecret, expectedProxySecret, proxyIp) ? proxyIp
      : undefined
    if (request.headers.get("host")?.toLowerCase() !== host || !clientIp) {
      return new Response("Forbidden", {
        status: 403,
        headers: { "cache-control": "no-store" },
      })
    }

    // All consumers (HTTP context, OAuth helpers and both realtime transports)
    // now resolve the same authenticated identity, with no forged fallback.
    request.headers.set(canonicalIpHeader, clientIp)
    return undefined
  }
}
