import { trimUrlToken } from "../../../normalize.js"
import type { NotionParsedResourceType, NotionParsedUrl } from "./types.js"

const notionHosts = new Set(["notion.so", "www.notion.so", "app.notion.com"])
const notionSiteSuffix = ".notion.site"
const uuidPattern = /[0-9a-fA-F]{32}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/g
const trackingQueryPrefixes = ["utm_"]
const trackingQueryKeys = new Set(["fbclid", "gclid", "gbraid", "igshid", "mc_cid", "mc_eid", "msclkid"])
const sensitiveQueryTokens = new Set([
  "access",
  "auth",
  "bearer",
  "code",
  "key",
  "jwt",
  "oauth",
  "password",
  "refresh",
  "secret",
  "session",
  "signature",
  "sso",
  "token",
])

export function parseNotionUrl(input: string): NotionParsedUrl | null {
  const raw = trimUrlToken(input)
  if (!raw) {
    return null
  }

  const withScheme = raw.toLowerCase().startsWith("www.") ? `https://${raw}` : raw
  let url: URL
  try {
    url = new URL(withScheme)
  } catch {
    return null
  }

  if (url.protocol !== "https:" && url.protocol !== "http:") {
    return null
  }
  if (url.username || url.password) {
    return null
  }

  const host = url.hostname.toLowerCase()
  if (!isNotionWebHost(host)) {
    return null
  }

  if (hasSensitiveQuery(url)) {
    return null
  }

  stripTrackingParams(url)
  url.protocol = "https:"

  const parsed = extractNotionId(url)
  if (!parsed) {
    return null
  }

  return {
    provider: "notion",
    resourceType: parsed.resourceType,
    resourceId: parsed.id,
    originalUrl: raw,
    normalizedUrl: url.toString(),
    meta: {
      host,
    },
  }
}

export function isNotionWebHost(hostname: string): boolean {
  const host = hostname.toLowerCase()
  return notionHosts.has(host) || host.endsWith(notionSiteSuffix)
}

function extractNotionId(url: URL): { id: string; resourceType: NotionParsedResourceType } | null {
  const hashId = lastUuid(url.hash)
  if (hashId) {
    return { id: formatUuid(hashId), resourceType: "block" }
  }

  const pathId = lastUuid(url.pathname)
  if (pathId) {
    return { id: formatUuid(pathId), resourceType: "unknown" }
  }

  return null
}

function lastUuid(input: string): string | null {
  const matches = input.match(uuidPattern)
  return matches?.at(-1) ?? null
}

function formatUuid(input: string): string {
  const compact = input.replaceAll("-", "").toLowerCase()
  return `${compact.slice(0, 8)}-${compact.slice(8, 12)}-${compact.slice(12, 16)}-${compact.slice(16, 20)}-${compact.slice(20)}`
}

function hasSensitiveQuery(url: URL): boolean {
  for (const key of url.searchParams.keys()) {
    const parts = key
      .trim()
      .replace(/([a-z0-9])([A-Z])/g, "$1-$2")
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter(Boolean)

    if (parts.some((part) => sensitiveQueryTokens.has(part))) {
      return true
    }
  }
  return false
}

function stripTrackingParams(url: URL) {
  for (const key of Array.from(url.searchParams.keys())) {
    const normalizedKey = key.toLowerCase()
    if (
      trackingQueryKeys.has(normalizedKey) ||
      trackingQueryPrefixes.some((prefix) => normalizedKey.startsWith(prefix)) ||
      normalizedKey === "pvs" ||
      normalizedKey === "source"
    ) {
      url.searchParams.delete(key)
    }
  }
}
