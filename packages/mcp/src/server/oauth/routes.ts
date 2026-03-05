import type { McpConfig } from "../config"
import { withJson } from "../http/response"
import { MCP_SUPPORTED_SCOPES } from "@inline-chat/oauth-core"

const PROXIED_OAUTH_PATHS = new Set([
  "/oauth/register",
  "/register",
  "/oauth/authorize",
  "/authorize",
  "/oauth/authorize/send-email-code",
  "/oauth/authorize/verify-email-code",
  "/oauth/authorize/consent",
  "/oauth/token",
  "/token",
  "/oauth/revoke",
  "/revoke",
])

function oauthEndpoint(base: string, path: string): string {
  const normalizedBase = base.endsWith("/") ? base : `${base}/`
  return new URL(path.replace(/^\//, ""), normalizedBase).toString()
}

function normalizeForwardedFor(value: string | null): string {
  if (!value) return "unknown"
  const first = value.split(",", 1)[0]?.trim().toLowerCase()
  return first && first.length > 0 ? first : "unknown"
}

async function proxyToOauthServer(req: Request, url: URL, config: McpConfig): Promise<Response> {
  const upstreamUrl = new URL(`${url.pathname}${url.search}`, config.oauthProxyBaseUrl)

  const headers = new Headers(req.headers)
  headers.delete("host")
  headers.set("x-forwarded-for", normalizeForwardedFor(req.headers.get("x-forwarded-for")))
  headers.set("x-forwarded-host", req.headers.get("host") ?? url.host)
  headers.set("x-forwarded-proto", url.protocol.replace(":", ""))

  const hasBody = req.method !== "GET" && req.method !== "HEAD"
  const body = hasBody ? await req.arrayBuffer() : undefined
  if (!hasBody) {
    headers.delete("content-length")
  }

  const upstream = await fetch(upstreamUrl, {
    method: req.method,
    headers,
    body,
    redirect: "manual",
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
        scopes_supported: [...MCP_SUPPORTED_SCOPES],
        bearer_methods_supported: ["header"],
      })
    }

    if (!PROXIED_OAUTH_PATHS.has(url.pathname)) {
      return null
    }

    try {
      return await proxyToOauthServer(req, url, config)
    } catch {
      return withJson({ error: "oauth_upstream_unavailable" }, { status: 502 })
    }
  },
}
