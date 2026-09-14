import {
  DEFAULT_DESCRIPTION_LENGTH,
  DEFAULT_MAX_REDIRECTS,
  DEFAULT_SITE_NAME_LENGTH,
  DEFAULT_TIMEOUT_MS,
  DEFAULT_TITLE_LENGTH,
  DEFAULT_USER_AGENT,
} from "../constants.js"
import { parseJsonObject } from "../json.js"
import { previewLayout } from "../layout.js"
import { defaultLookup, fetchWithRedirects, readResponseText } from "../network.js"
import { normalizeMetadataUrl } from "../normalize.js"
import { asFiniteNumber, asString, cleanField } from "../text.js"
import type { FetchUrlPreviewOptions, UrlPreviewResult } from "../types.js"
import type { UrlPreviewProvider } from "./types.js"

const FIGMA_OEMBED_URL = "https://www.figma.com/api/oembed"

export const figmaProvider: UrlPreviewProvider = {
  name: "figma",
  canHandle: isFigmaUrl,
  fetch: fetchFigmaPreview,
}

export function isFigmaUrl(url: string): boolean {
  try {
    const host = new URL(url).hostname.toLowerCase().replace(/^www\./, "")
    return host === "figma.com"
  } catch {
    return false
  }
}

async function fetchFigmaPreview(
  url: string,
  options: FetchUrlPreviewOptions,
): Promise<UrlPreviewResult | null> {
  const endpoint = new URL(FIGMA_OEMBED_URL)
  endpoint.searchParams.set("url", url)

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
  const description = cleanField(
    asString(data["description"]),
    options.maxDescriptionLength ?? DEFAULT_DESCRIPTION_LENGTH,
  )
  const siteName =
    cleanField(asString(data["provider_name"]), options.maxSiteNameLength ?? DEFAULT_SITE_NAME_LENGTH) ?? "Figma"
  const finalUrl = normalizeMetadataUrl(asString(data["url"]), url) ?? url
  const thumbnailUrl = normalizeMetadataUrl(asString(data["thumbnail_url"]), response.finalUrl)
  const thumbnailWidth = asFiniteNumber(data["thumbnail_width"]) ?? undefined
  const thumbnailHeight = asFiniteNumber(data["thumbnail_height"]) ?? undefined
  const media = thumbnailUrl
    ? {
        kind: "photo" as const,
        url: thumbnailUrl,
        width: thumbnailWidth,
        height: thumbnailHeight,
      }
    : undefined

  if (!title && !description && !thumbnailUrl) {
    return null
  }

  return {
    url,
    finalUrl,
    siteName,
    title: title ?? undefined,
    description: description ?? undefined,
    imageUrl: thumbnailUrl ?? undefined,
    mediaType: media ? "image" : undefined,
    media,
    layout: media ? previewLayout(media) : undefined,
    provider: "figma",
  }
}
