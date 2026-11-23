import { OauthModel } from "@in/server/db/models/oauth"
import { GENERIC_VIA_AGENT } from "@in/server/modules/message/viaAgents"
import { oauthClientViaApp } from "@in/server/modules/oauth/clientTrust"

/**
 * Who an OAuth connection is, for telemetry: Sentry span attributes and
 * PlanetScale Insights query tags. Never an authorization input.
 *
 * - `app` is the verified identity `oauthClientViaApp` derives from redirect
 *   URIs (chatgpt, claude, a known local agent) or "agent".
 * - `name` is the self-reported registration name, normalized. Anyone can
 *   register any name, so it is only shown next to an unverified app.
 * - `label` is the one bounded value to group by: the verified app, or
 *   `other:<name>` so a client calling itself "ChatGPT" never merges with the
 *   real one.
 */
export type OAuthClientLabel = { app: string; name: string; label: string }

export type OAuthAttribution = OAuthClientLabel & {
  grantId: string
  clientId: string
}

const MAX_NAME_LENGTH = 32

export const normalizeOAuthClientName = (name: string | null | undefined): string => {
  const normalized = (name ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, MAX_NAME_LENGTH)
    .replace(/-+$/g, "")
  return normalized || "unnamed"
}

export const oauthClientLabel = (client: { redirectUris: string[]; clientName: string | null }): OAuthClientLabel => {
  const app = oauthClientViaApp(client)
  const name = normalizeOAuthClientName(client.clientName)
  return { app, name, label: app === GENERIC_VIA_AGENT ? `other:${name}` : app }
}

/**
 * Span attributes for a connection. Keys avoid Sentry's default scrubbing
 * words ("auth", "token", "secret", ...): `oauth.*` keys arrived as
 * "[Filtered]", so they use `integration.*` instead.
 */
export const integrationSpanAttributes = (input: {
  label: OAuthClientLabel | null
  clientId: string
  grantId: string
}): Record<string, string> => ({
  "integration.client": input.label?.label ?? "other:unnamed",
  "integration.app": input.label?.app ?? GENERIC_VIA_AGENT,
  "integration.name": input.label?.name ?? "unnamed",
  "integration.client_id": input.clientId,
  "integration.grant_id": input.grantId,
})

/** Grant ids are server-minted UUIDs; anything else is never looked up. */
const GRANT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

const CACHE_TTL_MS = 60_000
const MAX_CACHED_GRANTS = 2_000

type Entry = { value: OAuthAttribution | null; ownerUserId: number | null; expiresAtMs: number }
const cache = new Map<string, Entry>()
const inFlight = new Map<string, Promise<Entry>>()

const load = async (grantId: string, nowMs: number): Promise<Entry> => {
  const grant = await OauthModel.getGrant(grantId)
  if (!grant || grant.revokedAtMs != null) {
    return { value: null, ownerUserId: null, expiresAtMs: nowMs + CACHE_TTL_MS }
  }
  const client = await OauthModel.getClient(grant.clientId)
  const label = client ? oauthClientLabel(client) : { app: GENERIC_VIA_AGENT, name: "unnamed", label: "other:unnamed" }
  return {
    value: { ...label, grantId: grant.id, clientId: grant.clientId },
    ownerUserId: grant.inlineUserId,
    expiresAtMs: nowMs + CACHE_TTL_MS,
  }
}

/**
 * The attribution a caller claims for its request, if that grant belongs to the
 * authenticated user and is live. A wrong or foreign grant id yields null, so a
 * caller can at most label its own traffic with one of its own connections.
 * Results are cached for a minute per process; failures attribute nothing.
 */
export const resolveOAuthAttribution = async (
  grantId: string | null | undefined,
  userId: number,
  nowMs: number = Date.now(),
): Promise<OAuthAttribution | null> => {
  if (!grantId || !GRANT_ID.test(grantId)) return null
  const key = grantId.toLowerCase()
  let entry = cache.get(key)
  if (!entry || entry.expiresAtMs <= nowMs) {
    let pending = inFlight.get(key)
    if (!pending) {
      pending = load(key, nowMs).finally(() => inFlight.delete(key))
      inFlight.set(key, pending)
    }
    try {
      entry = await pending
    } catch {
      return null
    }
    cache.delete(key)
    cache.set(key, entry)
    if (cache.size > MAX_CACHED_GRANTS) cache.delete(cache.keys().next().value!)
  }
  return entry.ownerUserId === userId ? entry.value : null
}

/** Test seam. */
export const resetOAuthAttributionCacheForTests = (): void => {
  cache.clear()
  inFlight.clear()
}
