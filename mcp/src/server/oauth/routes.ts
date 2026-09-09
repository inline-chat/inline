import type { McpConfig } from "../config"
import { withJson } from "../http/response"
import { MCP_RESOURCE_SCOPES, MCP_SUPPORTED_SCOPES } from "@inline-chat/oauth-core"

const PROXIED_OAUTH_PATHS = new Set([
  "/oauth/register",
  "/register",
  "/oauth/authorize",
  "/authorize",
  "/oauth/authorize/send-email-code",
  "/oauth/authorize/verify-email-code",
  "/oauth/authorize/send-sms-code",
  "/oauth/authorize/verify-sms-code",
  "/oauth/authorize/continue",
  "/oauth/authorize/consent",
  "/oauth/token",
  "/token",
  "/oauth/revoke",
  "/revoke",
])
const MAX_OAUTH_PROXY_BODY_BYTES = 64 * 1024
const OAUTH_PROXY_TIMEOUT_MS = 15_000

class OAuthRequestTooLargeError extends Error {}

function oauthEndpoint(base: string, path: string): string {
  const normalizedBase = base.endsWith("/") ? base : `${base}/`
  return new URL(path.replace(/^\//, ""), normalizedBase).toString()
}

function normalizeForwardedFor(value: string | null): string {
  if (!value) return "unknown"
  const first = value.split(",", 1)[0]?.trim().toLowerCase()
  return first && first.length > 0 ? first : "unknown"
}

async function readRequestBodyLimited(req: Request): Promise<Uint8Array> {
  const contentLength = Number(req.headers.get("content-length"))
  if (Number.isFinite(contentLength) && contentLength > MAX_OAUTH_PROXY_BODY_BYTES) {
    throw new OAuthRequestTooLargeError()
  }
  if (!req.body) return new Uint8Array()

  const reader = req.body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    if (!value) continue
    total += value.byteLength
    if (total > MAX_OAUTH_PROXY_BODY_BYTES) {
      try {
        await reader.cancel("oauth_request_too_large")
      } catch {
      }
      throw new OAuthRequestTooLargeError()
    }
    chunks.push(value)
  }

  const body = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    body.set(chunk, offset)
    offset += chunk.byteLength
  }
  return body
}

async function proxyToOauthServer(req: Request, url: URL, config: McpConfig): Promise<Response> {
  const upstreamUrl = new URL(`${url.pathname}${url.search}`, config.oauthProxyBaseUrl)

  const headers = new Headers(req.headers)
  headers.delete("host")
  headers.set("x-forwarded-for", normalizeForwardedFor(req.headers.get("x-forwarded-for")))
  headers.set("x-forwarded-host", req.headers.get("host") ?? url.host)
  headers.set("x-forwarded-proto", url.protocol.replace(":", ""))

  const hasBody = req.method !== "GET" && req.method !== "HEAD"
  const body = hasBody ? await readRequestBodyLimited(req) : undefined
  if (!hasBody) {
    headers.delete("content-length")
  } else {
    headers.delete("transfer-encoding")
    headers.set("content-length", String(body?.byteLength ?? 0))
  }

  const upstream = await fetch(upstreamUrl, {
    method: req.method,
    headers,
    body,
    redirect: "manual",
    signal: AbortSignal.timeout(OAUTH_PROXY_TIMEOUT_MS),
  })

  return new Response(upstream.body, {
    status: upstream.status,
    headers: upstream.headers,
  })
}

export const OAuth = {
  async handle(req: Request, url: URL, config: McpConfig): Promise<Response | null> {
    if (url.pathname === "/.well-known/oauth-authorization-server") {
      return withJson({
        issuer: config.oauthIssuer,
        authorization_endpoint: oauthEndpoint(config.oauthIssuer, "/oauth/authorize"),
        token_endpoint: oauthEndpoint(config.oauthIssuer, "/oauth/token"),
        registration_endpoint: oauthEndpoint(config.oauthIssuer, "/oauth/register"),
        revocation_endpoint: oauthEndpoint(config.oauthIssuer, "/oauth/revoke"),
        scopes_supported: [...MCP_SUPPORTED_SCOPES],
        response_types_supported: ["code"],
        grant_types_supported: ["authorization_code", "refresh_token"],
        token_endpoint_auth_methods_supported: ["none"],
        code_challenge_methods_supported: ["S256"],
      })
    }

    if (url.pathname === "/.well-known/oauth-protected-resource") {
      return withJson({
        resource: config.issuer,
        authorization_servers: [config.oauthIssuer],
        scopes_supported: [...MCP_RESOURCE_SCOPES],
        bearer_methods_supported: ["header"],
        resource_name: "Inline MCP",
        resource_documentation: "https://inline.chat",
      })
    }

    if (!PROXIED_OAUTH_PATHS.has(url.pathname)) {
      return null
    }

    if (req.method === "GET" && (url.pathname === "/authorize" || url.pathname === "/oauth/authorize")) {
      return new Response(null, {
        status: 307,
        headers: {
          location: oauthEndpoint(config.oauthIssuer, `${url.pathname}${url.search}`),
          "cache-control": "no-store",
        },
      })
    }

    try {
      return await proxyToOauthServer(req, url, config)
    } catch (error) {
      if (error instanceof OAuthRequestTooLargeError) {
        return withJson({ error: "request_too_large" }, { status: 413 })
      }
      return withJson({ error: "oauth_upstream_unavailable" }, { status: 502 })
    }
  },
}
