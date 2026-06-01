import { filterPreviewUrl } from "./filters.js"

const trackingQueryPrefixes = ["utm_"]
const trackingQueryKeys = new Set([
  "fbclid",
  "gclid",
  "gbraid",
  "igshid",
  "mc_cid",
  "mc_eid",
  "msclkid",
  "ref",
  "spm",
  "wbraid",
])

export function normalizePreviewUrl(input: string): string | null {
  const trimmed = trimUrlToken(input)
  if (!trimmed) {
    return null
  }

  const withScheme = trimmed.toLowerCase().startsWith("www.") ? `https://${trimmed}` : trimmed

  try {
    const url = new URL(withScheme)
    if (url.protocol !== "http:" && url.protocol !== "https:") {
      return null
    }
    if (url.username || url.password) {
      return null
    }

    url.hash = ""
    stripTrackingParams(url)

    const filter = filterPreviewUrl(url)
    if (!filter.ok) {
      return null
    }

    return url.toString()
  } catch {
    return null
  }
}

export function normalizeMetadataUrl(url: string | undefined, baseUrl: string): string | null {
  if (!url) {
    return null
  }

  try {
    return normalizePreviewUrl(new URL(url, baseUrl).toString())
  } catch {
    return null
  }
}

export function trimUrlToken(input: string): string {
  let value = input.trim()
  value = value.replace(/^[<("'`]+/, "")
  value = value.replace(/[>"'`]+$/, "")

  while (/[.,!?;:]+$/.test(value)) {
    value = value.replace(/[.,!?;:]+$/, "")
  }

  while (value.endsWith(")") && countChar(value, ")") > countChar(value, "(")) {
    value = value.slice(0, -1)
  }

  return value
}

function stripTrackingParams(url: URL) {
  for (const key of Array.from(url.searchParams.keys())) {
    const normalizedKey = key.toLowerCase()
    if (
      trackingQueryKeys.has(normalizedKey) ||
      trackingQueryPrefixes.some((prefix) => normalizedKey.startsWith(prefix))
    ) {
      url.searchParams.delete(key)
    }
  }
}

function countChar(input: string, char: string): number {
  let count = 0
  for (const value of input) {
    if (value === char) {
      count += 1
    }
  }
  return count
}
