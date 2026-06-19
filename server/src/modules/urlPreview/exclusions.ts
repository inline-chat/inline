import { db } from "@in/server/db"
import { spaceUrlPreviewExclusions } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"

const maxHostLength = 253
const maxPathPrefixLength = 2048

type ExclusionTarget = {
  host: string
  path: string
}

type NormalizedExclusion = {
  host: string
  pathPrefix: string
}

export async function isSpaceUrlPreviewExcluded(input: {
  spaceId: number | null | undefined
  url: string
}): Promise<boolean> {
  if (!input.spaceId) {
    return false
  }

  const target = urlPreviewExclusionTarget(input.url)
  if (!target) {
    return false
  }

  const exclusions = await db
    .select({
      host: spaceUrlPreviewExclusions.host,
      pathPrefix: spaceUrlPreviewExclusions.pathPrefix,
    })
    .from(spaceUrlPreviewExclusions)
    .where(and(eq(spaceUrlPreviewExclusions.spaceId, input.spaceId), eq(spaceUrlPreviewExclusions.host, target.host)))

  return exclusions.some((exclusion) => exclusionMatchesTarget(exclusion, target))
}

export function normalizeSpaceUrlPreviewExclusion(
  hostInput: string,
  pathPrefixInput?: string,
): NormalizedExclusion | null {
  const host = normalizeHost(hostInput)
  const pathPrefix = normalizePathPrefixInput(pathPrefixInput)
  if (!host || pathPrefix === null) {
    return null
  }

  return { host, pathPrefix }
}

export function urlPreviewExclusionTarget(value: string): ExclusionTarget | null {
  const trimmed = value.trim()
  if (!trimmed) {
    return null
  }

  const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`
  let url: URL
  try {
    url = new URL(withScheme)
  } catch {
    return null
  }

  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return null
  }
  if (url.username || url.password || url.port) {
    return null
  }

  const host = normalizeHost(url.hostname)
  if (!host) {
    return null
  }

  const path = normalizePathPrefix(url.pathname)
  if (!path) {
    return null
  }

  return { host, path }
}

export function exclusionMatchesTarget(
  exclusion: { host: string; pathPrefix: string },
  target: ExclusionTarget,
): boolean {
  if (exclusion.host !== target.host) {
    return false
  }
  return exclusion.pathPrefix === "" || target.path.startsWith(exclusion.pathPrefix)
}

function normalizeHost(hostname: string): string | null {
  const host = hostname.trim().toLowerCase().replace(/\.$/, "")
  if (host.length === 0 || host.length > maxHostLength || host.includes("..")) {
    return null
  }
  if (!/^[a-z0-9.-]+$/.test(host)) {
    return null
  }
  if (host.startsWith(".") || host.endsWith(".") || host.startsWith("-") || host.endsWith("-")) {
    return null
  }
  for (const label of host.split(".")) {
    if (!label || label.startsWith("-") || label.endsWith("-")) {
      return null
    }
  }
  return host
}

function normalizePathPrefixInput(pathPrefix: string | undefined): string | null {
  const value = pathPrefix?.trim() ?? ""
  if (!value || value === "/") {
    return ""
  }
  if (value.includes("?") || value.includes("#")) {
    return null
  }

  const normalized = normalizePathPrefix(value)
  if (!normalized) {
    return null
  }
  return normalized === "/" ? "" : normalized
}

function normalizePathPrefix(pathname: string): string | null {
  if (!pathname || pathname === "/") {
    return "/"
  }
  if (!pathname.startsWith("/") || pathname.length > maxPathPrefixLength) {
    return null
  }
  return pathname
}
