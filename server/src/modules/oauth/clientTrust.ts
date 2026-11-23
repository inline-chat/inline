import { GENERIC_VIA_AGENT, VIA_AGENTS, knownViaApp } from "@in/server/modules/message/viaAgents"

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
  // Inline's published ChatGPT app. Each ChatGPT connector gets its own id in
  // this path, so only this exact id is ours; other connector ids stay unverified.
  "https://chatgpt.com/connector/oauth/88ba_DMdKte-",
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

/** Hosted assistants by the host of their verified callback. */
const VIA_APP_BY_VERIFIED_HOST: Readonly<Record<string, string>> = {
  "chatgpt.com": "chatgpt",
  "claude.ai": "claude",
  "claude.com": "claude",
}

/**
 * The agent an OAuth client sends messages as, for "Sent via <name>". A hosted
 * assistant is named only when every callback it registered is that
 * assistant's verified one, since a client could use any of them. A local
 * client is named by the name it registered with, like the CLI naming the
 * agent running it. Anything else is an unnamed agent.
 */
export function oauthClientViaApp(client: { redirectUris: string[]; clientName: string | null }): string {
  const apps = new Set<string>()
  for (const redirectUri of client.redirectUris) {
    const trust = oauthClientTrust(redirectUri)
    if (!trust.verified) return GENERIC_VIA_AGENT
    apps.add(trust.loopback ? "local" : VIA_APP_BY_VERIFIED_HOST[trust.host] ?? GENERIC_VIA_AGENT)
  }
  if (apps.size !== 1) return GENERIC_VIA_AGENT
  const [app] = apps
  if (app !== "local") return app ?? GENERIC_VIA_AGENT
  return viaAppForName(client.clientName)
}

function viaAppForName(name: string | null): string {
  const normalized = name?.trim().toLowerCase()
  if (!normalized) return GENERIC_VIA_AGENT
  const byId = knownViaApp(normalized.replaceAll(" ", "-"))
  if (byId !== GENERIC_VIA_AGENT) return byId
  const byName = Object.entries(VIA_AGENTS).find(([, displayName]) => displayName.toLowerCase() === normalized)
  return byName?.[0] ?? GENERIC_VIA_AGENT
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
