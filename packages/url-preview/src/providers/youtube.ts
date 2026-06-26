import {
  DEFAULT_MAX_REDIRECTS,
  DEFAULT_TIMEOUT_MS,
  DEFAULT_TITLE_LENGTH,
  DEFAULT_USER_AGENT,
} from "../constants.js"
import { firstMeta, parseHtml } from "../html.js"
import { metadataImageUrls, selectPreviewImage } from "../imageRoles.js"
import { parseJsonObject } from "../json.js"
import { defaultLookup, fetchWithRedirects, readResponseText, readResponseTextPrefix } from "../network.js"
import { normalizeMetadataUrl, normalizePreviewUrl } from "../normalize.js"
import { asFiniteNumber, asString, cleanField } from "../text.js"
import type { FetchUrlPreviewOptions, UrlPreviewResult } from "../types.js"
import type { UrlPreviewProvider } from "./types.js"

const YOUTUBE_OEMBED_URL = "https://www.youtube.com/oembed"
const YOUTUBE_PAGE_PREFIX_BYTES = 900 * 1024

type YouTubePageInfo = {
  title?: string
  imageUrl?: string
  authorPhotoUrl?: string
}

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
    return fetchYouTubePagePreview(normalized, options)
  }

  const author = cleanField(asString(data["author_name"]), options.maxSiteNameLength ?? 80)
  const thumbnailUrl = normalizeMetadataUrl(asString(data["thumbnail_url"]), response.finalUrl)
  const pageInfo = await fetchYouTubePageInfo(normalized, options).catch(() => null)
  const id = getYouTubeVideoId(normalized)
  if (!id) {
    return null
  }
  const width = asFiniteNumber(data["width"]) ?? undefined
  const height = asFiniteNumber(data["height"]) ?? undefined

  return {
    url: normalized,
    finalUrl: normalized,
    siteName: "YouTube",
    title,
    author: author ?? undefined,
    imageUrl: preferredThumbnailUrl(id, pageInfo?.imageUrl, thumbnailUrl),
    authorPhotoUrl: pageInfo?.authorPhotoUrl,
    mediaType: "video",
    media: {
      kind: "embed",
      url: youtubeEmbedUrl(id),
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

  const pageInfo = await readYouTubePageInfo(response.response, response.finalUrl, options)
  if (!pageInfo?.title && !pageInfo?.imageUrl && !pageInfo?.authorPhotoUrl) {
    return fallbackYouTubePreview(normalized, id)
  }

  return {
    url: normalized,
    finalUrl: normalized,
    siteName: "YouTube",
    title: pageInfo.title ?? "YouTube video",
    imageUrl: preferredThumbnailUrl(id, pageInfo.imageUrl),
    authorPhotoUrl: pageInfo.authorPhotoUrl,
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

async function fetchYouTubePageInfo(
  normalized: string,
  options: FetchUrlPreviewOptions,
): Promise<YouTubePageInfo | null> {
  const response = await fetchWithRedirects(normalized, {
    fetchImpl: options.fetchImpl ?? fetch,
    lookup: options.lookup ?? defaultLookup,
    timeoutMs: options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    maxRedirects: options.maxRedirects ?? DEFAULT_MAX_REDIRECTS,
    userAgent: options.userAgent ?? DEFAULT_USER_AGENT,
    accept: "text/html,application/xhtml+xml",
  }).catch(() => null)

  if (!response?.response.ok) {
    return null
  }

  return readYouTubePageInfo(response.response, response.finalUrl, options)
}

async function readYouTubePageInfo(
  response: Response,
  finalUrl: string,
  options: FetchUrlPreviewOptions,
): Promise<YouTubePageInfo | null> {
  const html = await readResponseTextPrefix(response, YOUTUBE_PAGE_PREFIX_BYTES)
  const meta = await parseHtml(html)
  const title = cleanField(
    firstMeta(meta, ["og:title", "twitter:title", "title"]) ?? meta.title?.replace(/\s+-\s+YouTube$/i, ""),
    options.maxTitleLength ?? DEFAULT_TITLE_LENGTH,
  )
  const image = selectPreviewImage(finalUrl, finalUrl, metadataImageUrls(meta, finalUrl))
  const authorPhotoUrl = image.authorPhotoUrl ?? extractYouTubeAuthorPhotoUrl(html, finalUrl)

  if (!title && !image.primaryUrl && !authorPhotoUrl) {
    return null
  }

  return {
    title: title ?? undefined,
    imageUrl: image.primaryUrl,
    authorPhotoUrl,
  }
}

function fallbackYouTubePreview(normalized: string, id: string): UrlPreviewResult {
  return {
    url: normalized,
    finalUrl: normalized,
    siteName: "YouTube",
    title: "YouTube video",
    imageUrl: preferredThumbnailUrl(id),
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
  return `https://i.ytimg.com/vi/${id}/mqdefault.jpg`
}

function preferredThumbnailUrl(id: string, ...candidates: Array<string | null | undefined>): string {
  for (const candidate of candidates) {
    const url = normalizeMetadataUrl(candidate ?? undefined, `https://www.youtube.com/watch?v=${id}`)
    if (url) {
      return normalizeYouTubeThumbnailUrl(url, id)
    }
  }

  return thumbnailUrl(id)
}

function normalizeYouTubeThumbnailUrl(value: string, id: string): string {
  try {
    const parsed = new URL(value)
    const host = parsed.hostname.toLowerCase().replace(/^www\./, "")
    if (host !== "i.ytimg.com" && host !== "img.youtube.com") {
      return value
    }

    const parts = parsed.pathname.split("/").filter(Boolean)
    const videoPathIndex = parts.findIndex((part) => part === "vi" || part === "vi_webp")
    if (videoPathIndex < 0 || parts[videoPathIndex + 1] !== id) {
      return value
    }

    const fileName = parts[videoPathIndex + 2]?.toLowerCase()
    if (fileName === "default.jpg" || fileName === "hqdefault.jpg" || fileName === "sddefault.jpg") {
      return thumbnailUrl(id)
    }
  } catch {
    return value
  }

  return value
}

function youtubeEmbedUrl(id: string): string {
  return `https://www.youtube.com/embed/${id}`
}

function extractYouTubeAuthorPhotoUrl(html: string, finalUrl: string): string | undefined {
  const ownerMatch = html.match(/"videoOwnerRenderer":\{"thumbnail":\{"thumbnails":(\[[^\]]+\])/)
  const ownerUrl = ownerMatch?.[1] ? largestThumbnailUrl(ownerMatch[1], finalUrl) : undefined
  if (ownerUrl) {
    return ownerUrl
  }

  const channelMatch = html.match(/"channelThumbnail":\{"thumbnails":(\[[^\]]+\])/)
  return channelMatch?.[1] ? largestThumbnailUrl(channelMatch[1], finalUrl) : undefined
}

function largestThumbnailUrl(json: string, finalUrl: string): string | undefined {
  let value: unknown
  try {
    value = JSON.parse(json)
  } catch {
    return undefined
  }

  if (!Array.isArray(value)) {
    return undefined
  }

  let best: { url: string; size: number } | undefined
  for (const item of value) {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      continue
    }

    const record = item as Record<string, unknown>
    const url = normalizeMetadataUrl(asString(record["url"]), finalUrl)
    if (!url) {
      continue
    }

    const width = asFiniteNumber(record["width"]) ?? 0
    const height = asFiniteNumber(record["height"]) ?? 0
    const size = width * height
    if (!best || size >= best.size) {
      best = { url, size }
    }
  }

  return best?.url
}

function getYouTubeVideoId(url: string): string | null {
  try {
    const parsed = new URL(url)
    const host = parsed.hostname.toLowerCase().replace(/^www\./, "")

    if (host === "youtu.be") {
      return sanitizeVideoId(parsed.pathname.split("/").filter(Boolean)[0])
    }

    if (
      host === "youtube.com" ||
      host === "m.youtube.com" ||
      host === "music.youtube.com" ||
      host === "youtube-nocookie.com"
    ) {
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
