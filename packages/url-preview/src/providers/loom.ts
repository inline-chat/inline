import {
  DEFAULT_DESCRIPTION_LENGTH,
  DEFAULT_MAX_REDIRECTS,
  DEFAULT_TIMEOUT_MS,
  DEFAULT_TITLE_LENGTH,
  DEFAULT_USER_AGENT,
} from "../constants.js"
import { parseJsonObject } from "../json.js"
import { defaultLookup, fetchWithRedirects, readResponseText } from "../network.js"
import { normalizeMetadataUrl } from "../normalize.js"
import { asFiniteNumber, asString, cleanField } from "../text.js"
import type { FetchUrlPreviewOptions, UrlPreviewResult } from "../types.js"
import type { UrlPreviewProvider } from "./types.js"

const LOOM_OEMBED_URL = "https://www.loom.com/v1/oembed"

export const loomProvider: UrlPreviewProvider = {
  name: "loom",
  canHandle: isLoomUrl,
  exclusive: true,
  fetch: fetchLoomPreview,
}

export function isLoomUrl(url: string): boolean {
  try {
    const parsed = new URL(url)
    const host = parsed.hostname.toLowerCase()
    return (host === "loom.com" || host === "www.loom.com") && parsed.pathname.startsWith("/share/")
  } catch {
    return false
  }
}

async function fetchLoomPreview(
  url: string,
  options: FetchUrlPreviewOptions,
): Promise<UrlPreviewResult | null> {
  const endpoint = new URL(LOOM_OEMBED_URL)
  endpoint.searchParams.set("url", url)
  endpoint.searchParams.set("format", "json")

  const response = await fetchWithRedirects(endpoint.toString(), {
    fetchImpl: options.fetchImpl ?? fetch,
    lookup: options.lookup ?? defaultLookup,
    timeoutMs: options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    maxRedirects: options.maxRedirects ?? DEFAULT_MAX_REDIRECTS,
    userAgent: options.userAgent ?? DEFAULT_USER_AGENT,
    accept: "application/json",
  })

  if (!response.response.ok) {
    return null
  }

  const text = await readResponseText(response.response, 128 * 1024)
  const data = parseJsonObject(text)
  if (!data) {
    return null
  }
  const title = cleanField(asString(data["title"]), options.maxTitleLength ?? DEFAULT_TITLE_LENGTH)
  if (!title) {
    return null
  }

  const description = cleanField(asString(data["description"]), options.maxDescriptionLength ?? DEFAULT_DESCRIPTION_LENGTH)
  const thumbnailUrl = normalizeMetadataUrl(asString(data["thumbnail_url"]), response.finalUrl)
  const duration = asFiniteNumber(data["duration"])
  const embedUrl = normalizeMetadataUrl(extractIframeSrc(asString(data["html"])), response.finalUrl) ?? url
  const width = asFiniteNumber(data["width"]) ?? undefined
  const height = asFiniteNumber(data["height"]) ?? undefined

  return {
    url,
    finalUrl: url,
    siteName: "Loom",
    title,
    description: description ?? undefined,
    imageUrl: thumbnailUrl ?? undefined,
    duration: duration == null ? undefined : Math.round(duration),
    mediaType: "video",
    media: {
      kind: "embed",
      url: embedUrl,
      embedType: "iframe",
      width,
      height,
      duration: duration == null ? undefined : Math.round(duration),
    },
    layout: {
      hasLargeMedia: true,
      showLargeMedia: true,
    },
    provider: "loom",
  }
}

function extractIframeSrc(html: string | undefined): string | undefined {
  return html?.match(/<iframe\b[^>]*\bsrc=["']([^"']+)["']/i)?.[1]
}
