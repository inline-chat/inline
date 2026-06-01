import {
  DEFAULT_MAX_REDIRECTS,
  DEFAULT_TIMEOUT_MS,
  DEFAULT_TITLE_LENGTH,
  DEFAULT_USER_AGENT,
} from "../constants.js"
import { firstMeta, parseHtml } from "../html.js"
import { parseJsonObject } from "../json.js"
import { defaultLookup, fetchWithRedirects, readResponseText, readResponseTextPrefix } from "../network.js"
import { normalizeMetadataUrl, normalizePreviewUrl } from "../normalize.js"
import { asFiniteNumber, asString, cleanField } from "../text.js"
import type { FetchUrlPreviewOptions, UrlPreviewResult } from "../types.js"
import type { UrlPreviewProvider } from "./types.js"

const YOUTUBE_OEMBED_URL = "https://www.youtube.com/oembed"
const YOUTUBE_PAGE_PREFIX_BYTES = 900 * 1024

export const youtubeProvider: UrlPreviewProvider = {
  name: "youtube",
  canHandle: isYouTubeUrl,
  exclusive: true,
  fetch: fetchYouTubePreview,
}

export function isYouTubeUrl(url: string): boolean {
  return getYouTubeVideoId(url) !== null
}

export function normalizeYouTubeUrl(url: string): string | null {
  const id = getYouTubeVideoId(url)
  if (!id) {
    return null
  }
  return normalizePreviewUrl(`https://www.youtube.com/watch?v=${id}`)
}

async function fetchYouTubePreview(
  url: string,
  options: FetchUrlPreviewOptions,
): Promise<UrlPreviewResult | null> {
  const normalized = normalizeYouTubeUrl(url)
  if (!normalized) {
    return null
  }

  const endpoint = new URL(YOUTUBE_OEMBED_URL)
  endpoint.searchParams.set("url", normalized)
  endpoint.searchParams.set("format", "json")

  const response = await fetchWithRedirects(endpoint.toString(), {
    fetchImpl: options.fetchImpl ?? fetch,
    lookup: options.lookup ?? defaultLookup,
    timeoutMs: options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    maxRedirects: options.maxRedirects ?? DEFAULT_MAX_REDIRECTS,
    userAgent: options.userAgent ?? DEFAULT_USER_AGENT,
    accept: "application/json",
  }).catch(() => null)

  if (!response?.response.ok) {
    return fetchYouTubePagePreview(normalized, options)
  }

  const text = await readResponseText(response.response, 128 * 1024).catch(() => null)
  if (!text) {
    return fetchYouTubePagePreview(normalized, options)
  }

  const data = parseJsonObject(text)
  if (!data) {
    return fetchYouTubePagePreview(normalized, options)
  }
  const title = cleanField(asString(data["title"]), options.maxTitleLength ?? DEFAULT_TITLE_LENGTH)
  if (!title) {
    return null
  }

  const author = cleanField(asString(data["author_name"]), options.maxSiteNameLength ?? 80)
  const thumbnailUrl = normalizeMetadataUrl(asString(data["thumbnail_url"]), response.finalUrl)
  const width = asFiniteNumber(data["width"]) ?? undefined
  const height = asFiniteNumber(data["height"]) ?? undefined

  return {
    url: normalized,
    finalUrl: normalized,
    siteName: "YouTube",
    title,
    author: author ?? undefined,
    imageUrl: thumbnailUrl ?? undefined,
    mediaType: "video",
    media: {
      kind: "embed",
      url: youtubeEmbedUrl(getYouTubeVideoId(normalized) ?? ""),
      embedType: "iframe",
      width,
      height,
    },
    layout: {
      hasLargeMedia: true,
      showLargeMedia: true,
    },
    provider: "youtube",
  }
}

async function fetchYouTubePagePreview(
  normalized: string,
  options: FetchUrlPreviewOptions,
): Promise<UrlPreviewResult | null> {
  const id = getYouTubeVideoId(normalized)
  if (!id) {
    return null
  }

  const response = await fetchWithRedirects(normalized, {
    fetchImpl: options.fetchImpl ?? fetch,
    lookup: options.lookup ?? defaultLookup,
    timeoutMs: options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    maxRedirects: options.maxRedirects ?? DEFAULT_MAX_REDIRECTS,
    userAgent: options.userAgent ?? DEFAULT_USER_AGENT,
    accept: "text/html,application/xhtml+xml",
  }).catch(() => null)

  if (!response?.response.ok) {
    return fallbackYouTubePreview(normalized, id)
  }

  const html = await readResponseTextPrefix(response.response, YOUTUBE_PAGE_PREFIX_BYTES)
  const meta = await parseHtml(html)
  const title = cleanField(
    firstMeta(meta, ["og:title", "twitter:title", "title"]) ?? meta.title?.replace(/\s+-\s+YouTube$/i, ""),
    options.maxTitleLength ?? DEFAULT_TITLE_LENGTH,
  )
  const imageUrl = normalizeMetadataUrl(
    firstMeta(meta, ["og:image:secure_url", "og:image:url", "og:image", "twitter:image", "twitter:image:src"]),
    response.finalUrl,
  )

  if (!title && !imageUrl) {
    return fallbackYouTubePreview(normalized, id)
  }

  return {
    url: normalized,
    finalUrl: normalized,
    siteName: "YouTube",
    title: title ?? "YouTube video",
    imageUrl: imageUrl ?? thumbnailUrl(id),
    mediaType: "video",
    media: {
      kind: "embed",
      url: youtubeEmbedUrl(id),
      embedType: "iframe",
    },
    layout: {
      hasLargeMedia: true,
      showLargeMedia: true,
    },
    provider: "youtube",
  }
}

function fallbackYouTubePreview(normalized: string, id: string): UrlPreviewResult {
  return {
    url: normalized,
    finalUrl: normalized,
    siteName: "YouTube",
    title: "YouTube video",
    imageUrl: thumbnailUrl(id),
    mediaType: "video",
    media: {
      kind: "embed",
      url: youtubeEmbedUrl(id),
      embedType: "iframe",
    },
    layout: {
      hasLargeMedia: true,
      showLargeMedia: true,
    },
    provider: "youtube",
  }
}

function thumbnailUrl(id: string): string {
  return `https://i.ytimg.com/vi/${id}/hqdefault.jpg`
}

function youtubeEmbedUrl(id: string): string {
  return `https://www.youtube.com/embed/${id}`
}

function getYouTubeVideoId(url: string): string | null {
  try {
    const parsed = new URL(url)
    const host = parsed.hostname.toLowerCase().replace(/^www\./, "")

    if (host === "youtu.be") {
      return sanitizeVideoId(parsed.pathname.split("/").filter(Boolean)[0])
    }

    if (host === "youtube.com" || host === "m.youtube.com" || host === "music.youtube.com") {
      if (parsed.pathname === "/watch") {
        return sanitizeVideoId(parsed.searchParams.get("v"))
      }

      const parts = parsed.pathname.split("/").filter(Boolean)
      if (parts[0] === "shorts" || parts[0] === "embed" || parts[0] === "live") {
        return sanitizeVideoId(parts[1])
      }
    }
  } catch {
    return null
  }

  return null
}

function sanitizeVideoId(value: string | null | undefined): string | null {
  if (!value || !/^[a-zA-Z0-9_-]{6,32}$/.test(value)) {
    return null
  }
  return value
}
