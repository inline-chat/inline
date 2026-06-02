import { normalizePreviewUrl, trimUrlToken } from "./normalize.js"
import { parseAuthenticatedPreviewUrl } from "./auth/registry.js"
import type { ParsedProviderUrl } from "./auth/types.js"

export type PreviewRoute =
  | { kind: "general"; url: string }
  | { kind: "authenticated"; parsedUrl: ParsedProviderUrl }

const rawUrlRegex = /(?:https?:\/\/|www\.)[^\s<>"'`]+/gi

export function routePreviewUrl(input: string): PreviewRoute | null {
  const raw = trimUrlToken(input)
  if (!raw) {
    return null
  }

  const authenticated = parseAuthenticatedPreviewUrl(raw)
  if (authenticated) {
    return { kind: "authenticated", parsedUrl: authenticated }
  }

  const normalized = normalizePreviewUrl(raw)
  if (!normalized) {
    return null
  }

  return { kind: "general", url: normalized }
}

export function extractPreviewRoutes(
  text: string,
  candidates: readonly string[] = [],
  options: { limit?: number } = {},
): PreviewRoute[] {
  const limit = options.limit ?? 3
  const routes: PreviewRoute[] = []
  const seen = new Set<string>()

  const append = (input: string) => {
    if (routes.length >= limit) {
      return
    }

    const route = routePreviewUrl(input)
    if (!route) {
      return
    }

    const key = previewRouteKey(route)
    if (seen.has(key)) {
      return
    }

    seen.add(key)
    routes.push(route)
  }

  for (const candidate of candidates) {
    append(candidate)
  }

  for (const match of text.matchAll(rawUrlRegex)) {
    append(match[0] ?? "")
  }

  return routes
}

function previewRouteKey(route: PreviewRoute): string {
  if (route.kind === "general") {
    return `general:${route.url}`
  }

  return `authenticated:${route.parsedUrl.provider}:${route.parsedUrl.resourceId}:${route.parsedUrl.normalizedUrl}`
}
