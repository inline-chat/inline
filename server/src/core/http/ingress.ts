import { timingSafeEqual } from "node:crypto"
import { isIP } from "node:net"
import type { ClientIpMode } from "./middleware"

export const ORIGIN_SECRET_HEADER = "x-inline-origin-secret"

/** Runs on the original Bun request, before HTTP middleware or any upgrade. */
export type IngressPolicy = (request: Request) => Response | undefined

const forwardedHeaders = [
  "cf-connecting-ip", "cf-connecting-ipv6", "true-client-ip",
  "x-real-ip", "x-forwarded-for", "x-forwarded", "forwarded",
  "fly-client-ip", "x-forwarded-host", "x-forwarded-proto", "x-forwarded-port",
  "x-inline-proxy-secret",
] as const

export const makeIngressPolicy = (
  env: Readonly<Record<string, string | undefined>>,
  clientIpMode: ClientIpMode,
): IngressPolicy | undefined => {
  const mode = env["INLINE_INGRESS_MODE"]
  const host = env["INLINE_INGRESS_HOST"]
  const secret = env["INLINE_ORIGIN_SECRET"]
  const directIpSource = env["INLINE_INGRESS_DIRECT_IP_SOURCE"]
  if (mode === undefined && host === undefined && secret === undefined && directIpSource === undefined) return undefined
  if (mode !== "cloudflare" && mode !== "cloudflare-optional") {
    throw new Error("INLINE_INGRESS_MODE must be cloudflare or cloudflare-optional when ingress configuration is present")
  }
  // One DNS hostname, without scheme, port, wildcard, or path. Never echo config.
  if (!host || host.length > 253 || !/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(host)) {
    throw new Error("INLINE_INGRESS_HOST must be a lowercase DNS hostname")
  }
  if ((mode === "cloudflare" && !secret) || (secret !== undefined && !/^[a-f0-9]{64}$/.test(secret))) {
    throw new Error("INLINE_ORIGIN_SECRET must contain 32 random bytes encoded as lowercase hex")
  }
  if (clientIpMode !== "cf-connecting-ip") {
    throw new Error("Cloudflare ingress requires INLINE_TRUSTED_CLIENT_IP_HEADER=cf-connecting-ip")
  }
  const expectedSecret = secret ? Buffer.from(secret, "ascii") : undefined
  // This fallback is explicitly tied to a trusted ingress deployment. Header
  // modes require the immediate reverse proxy to overwrite the chosen header
  // and prohibit direct access to the application port. Use socket otherwise.
  if (mode === "cloudflare-optional" &&
      directIpSource !== "socket" && directIpSource !== "fly-client-ip" && directIpSource !== "x-real-ip") {
    throw new Error("Cloudflare optional ingress requires an explicit direct IP source")
  }

  return (request) => {
    const suppliedSecret = request.headers.get(ORIGIN_SECRET_HEADER)
    const clientIp = request.headers.get("cf-connecting-ip")
    const fallbackIp = directIpSource && directIpSource !== "socket"
      ? request.headers.get(directIpSource)
      : undefined
    // Strip credentials and competing proxy identities even on rejected requests.
    // Keep the original Request: Bun owns its body, peer address, and upgrade state.
    request.headers.delete(ORIGIN_SECRET_HEADER)
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

    const validIp = (ip: string | null | undefined): ip is string =>
      !!ip && isIP(ip) !== 0 && !ip.includes("%")
    const trustedCloudflare = !!expectedSecret && !!suppliedSecret &&
      /^[a-f0-9]{64}$/.test(suppliedSecret) &&
      timingSafeEqual(Buffer.from(suppliedSecret, "ascii"), expectedSecret) &&
      validIp(clientIp)

    if (
      request.headers.get("host")?.toLowerCase() !== host ||
      (mode === "cloudflare" && !trustedCloudflare)
    ) {
      return new Response("Forbidden", {
        status: 403,
        headers: { "cache-control": "no-store" },
      })
    }

    // Keep one normalized identity for HTTP and both realtime transports.
    // Unauthenticated Cloudflare headers never influence the fallback identity.
    if (trustedCloudflare && clientIp) request.headers.set("cf-connecting-ip", clientIp)
    else if (validIp(fallbackIp)) request.headers.set("cf-connecting-ip", fallbackIp)
    return undefined
  }
}
