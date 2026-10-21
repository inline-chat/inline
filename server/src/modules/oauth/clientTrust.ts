/**
 * Anyone can register an OAuth client with any name, so a client name is
 * never evidence of who will receive access. Trust comes from where the
 * authorization code is sent:
 * - loopback redirects keep the code on the user's own machine;
 * - a short allowlist of exact callback URIs covers the hosted assistants we
 *   support. It is exact, not host-wide: other paths on these hosts (for
 *   example custom-GPT action callbacks) belong to whoever created them.
 */
const VERIFIED_REDIRECT_URIS = new Set([
  "https://chatgpt.com/connector_platform_oauth_redirect",
  "https://claude.ai/api/mcp/auth_callback",
  "https://claude.com/api/mcp/auth_callback",
])
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"])

export type OAuthClientTrust = {
  verified: boolean
  loopback: boolean
  /** Host that receives the authorization code, for display. */
  host: string
}

export function oauthClientTrust(redirectUri: string): OAuthClientTrust {
  let url: URL
  try {
    url = new URL(redirectUri)
  } catch {
    return { verified: false, loopback: false, host: redirectUri }
  }
  const hostname = url.hostname.toLowerCase()
  const loopback = url.protocol === "http:" && LOOPBACK_HOSTS.has(hostname)
  const verified = loopback || isVerifiedRedirect(url)
  return { verified, loopback, host: loopback ? "this computer" : url.host.toLowerCase() }
}

/** Exact match on scheme, host and path, with the default port, no query, fragment or userinfo. */
function isVerifiedRedirect(url: URL): boolean {
  if (url.protocol !== "https:" || url.port !== "" || url.search !== "" || url.hash !== "") return false
  if (url.username !== "" || url.password !== "") return false
  return VERIFIED_REDIRECT_URIS.has(`https://${url.hostname.toLowerCase()}${url.pathname}`)
}

const SCOPE_DESCRIPTIONS: Record<string, string> = {
  "messages:read": "Read messages in the spaces and chats you choose",
  "messages:write": "Send messages and reactions as you",
  "spaces:read": "See your spaces and their threads",
  offline_access: "Stay connected until you revoke access",
}

export function describeOAuthScopes(scope: string): string[] {
  return scope.split(/\s+/).filter(Boolean).map((value) => SCOPE_DESCRIPTIONS[value] ?? value)
}
