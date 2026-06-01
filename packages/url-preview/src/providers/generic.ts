import {
  DEFAULT_DESCRIPTION_LENGTH,
  DEFAULT_MAX_HTML_BYTES,
  DEFAULT_MAX_REDIRECTS,
  DEFAULT_SITE_NAME_LENGTH,
  DEFAULT_TIMEOUT_MS,
  DEFAULT_TITLE_LENGTH,
  DEFAULT_USER_AGENT,
} from "../constants.js"
import { firstMeta, parseHtml, type ParsedHtml } from "../html.js"
import { defaultLookup, fetchWithRedirects, readResponseTextPrefix } from "../network.js"
import { normalizeMetadataUrl } from "../normalize.js"
import { cleanField, hostLabel } from "../text.js"
import type { FetchUrlPreviewOptions, PreviewMedia, UrlPreviewResult } from "../types.js"

export async function fetchGenericPreview(
  originalUrl: string,
  options: FetchUrlPreviewOptions,
): Promise<UrlPreviewResult | null> {
  const response = await fetchWithRedirects(originalUrl, {
    fetchImpl: options.fetchImpl ?? fetch,
    lookup: options.lookup ?? defaultLookup,
    timeoutMs: options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    maxRedirects: options.maxRedirects ?? DEFAULT_MAX_REDIRECTS,
    userAgent: options.userAgent ?? DEFAULT_USER_AGENT,
    accept: "text/html,application/xhtml+xml",
  })

  if (!response.response.ok) {
    return null
  }

  const contentType = response.response.headers.get("content-type")?.toLowerCase() ?? ""
  if (contentType && !contentType.includes("text/html") && !contentType.includes("application/xhtml+xml")) {
    await response.response.body?.cancel().catch(() => undefined)
    return buildContentTypePreview(originalUrl, response.finalUrl, contentType, options)
  }

  const html = await readResponseTextPrefix(response.response, options.maxHtmlBytes ?? DEFAULT_MAX_HTML_BYTES)
  const meta = await parseHtml(html)
  return buildGenericPreview(originalUrl, response.finalUrl, meta, options)
}

function buildGenericPreview(
  originalUrl: string,
  finalUrl: string,
  meta: ParsedHtml,
  options: FetchUrlPreviewOptions,
): UrlPreviewResult | null {
  const title = cleanField(
    firstMeta(meta, ["og:title", "twitter:title"]) ?? meta.title,
    options.maxTitleLength ?? DEFAULT_TITLE_LENGTH,
  )
  const description = cleanField(
    firstMeta(meta, ["og:description", "twitter:description", "description"]),
    options.maxDescriptionLength ?? DEFAULT_DESCRIPTION_LENGTH,
  )
  const imageUrl = normalizeMetadataUrl(
    firstMeta(meta, ["og:image:secure_url", "og:image:url", "og:image", "twitter:image", "twitter:image:src"]),
    finalUrl,
  )
  const siteName = cleanField(
    firstMeta(meta, ["og:site_name", "application-name"]) ?? hostLabel(finalUrl),
    options.maxSiteNameLength ?? DEFAULT_SITE_NAME_LENGTH,
  )
  const media = detectMedia(meta, finalUrl, imageUrl ?? undefined)
  const mediaType = detectMediaType(meta, media)
  const duration = mediaDuration(media)

  if (!title && !description && !imageUrl) {
    return null
  }

  return {
    url: originalUrl,
    finalUrl,
    siteName: siteName ?? undefined,
    title: title ?? undefined,
    description: description ?? undefined,
    imageUrl: imageUrl ?? undefined,
    duration,
    mediaType,
    media,
    layout: media ? previewLayout(media) : undefined,
    provider: "generic",
  }
}

function buildContentTypePreview(
  originalUrl: string,
  finalUrl: string,
  contentType: string,
  options: FetchUrlPreviewOptions,
): UrlPreviewResult | null {
  const mediaType = detectMediaTypeFromContentType(contentType)
  if (!mediaType) {
    return null
  }
  const media = mediaFromContentType(finalUrl, contentType)

  return {
    url: originalUrl,
    finalUrl,
    siteName: cleanField(hostLabel(finalUrl), options.maxSiteNameLength ?? DEFAULT_SITE_NAME_LENGTH) ?? undefined,
    title: cleanField(fileTitle(finalUrl), options.maxTitleLength ?? DEFAULT_TITLE_LENGTH) ?? undefined,
    imageUrl: media?.kind === "photo" ? media.url : undefined,
    mediaType,
    media,
    layout: media ? previewLayout(media) : undefined,
    provider: "generic",
  }
}

function detectMedia(meta: ParsedHtml, finalUrl: string, imageUrl: string | undefined): PreviewMedia | undefined {
  const type = firstMeta(meta, ["og:type"])?.toLowerCase()
  const videoType = firstMeta(meta, ["og:video:type", "twitter:player:stream:content_type"])?.toLowerCase()
  const videoUrl = normalizeMetadataUrl(
    firstMeta(meta, ["og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream"]),
    finalUrl,
  )
  if (videoUrl) {
    return {
      kind: "external_video",
      url: videoUrl,
      mimeType: videoType ?? undefined,
      width: firstNumberMeta(meta, ["og:video:width", "twitter:player:width"]),
      height: firstNumberMeta(meta, ["og:video:height", "twitter:player:height"]),
      duration: firstNumberMeta(meta, ["og:video:duration", "video:duration", "duration"]),
    }
  }

  const playerUrl = normalizeMetadataUrl(firstMeta(meta, ["twitter:player"]), finalUrl)
  if (playerUrl && firstMeta(meta, ["twitter:card"])?.toLowerCase() === "player") {
    return {
      kind: "embed",
      url: playerUrl,
      embedType: "player",
      width: firstNumberMeta(meta, ["twitter:player:width", "og:video:width"]),
      height: firstNumberMeta(meta, ["twitter:player:height", "og:video:height"]),
      duration: firstNumberMeta(meta, ["og:video:duration", "video:duration", "duration"]),
    }
  }

  if ((type === "image" || type === "photo") && imageUrl) {
    return {
      kind: "photo",
      url: imageUrl,
      width: firstNumberMeta(meta, ["og:image:width", "twitter:image:width"]),
      height: firstNumberMeta(meta, ["og:image:height", "twitter:image:height"]),
    }
  }

  return undefined
}

function detectMediaType(meta: ParsedHtml, media: PreviewMedia | undefined): UrlPreviewResult["mediaType"] {
  const type = firstMeta(meta, ["og:type"])?.toLowerCase()
  const videoType = firstMeta(meta, ["og:video:type", "twitter:player:stream:content_type"])?.toLowerCase()
  const twitterCard = firstMeta(meta, ["twitter:card"])?.toLowerCase()

  if (media?.kind === "external_video" || media?.kind === "embed") {
    return "video"
  }

  if (media?.kind === "photo") {
    return "image"
  }

  if (media?.kind === "document") {
    return "document"
  }

  if (
    type?.startsWith("video") ||
    videoType?.startsWith("video/") ||
    firstMeta(meta, ["og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream", "twitter:player"]) ||
    twitterCard === "player"
  ) {
    return "video"
  }

  if (type === "image" || type === "photo") {
    return "image"
  }

  if (type === "article") {
    return "article"
  }

  return undefined
}

function detectMediaTypeFromContentType(contentType: string): UrlPreviewResult["mediaType"] | null {
  const base = baseContentType(contentType)
  if (!base) {
    return null
  }

  if (base.startsWith("video/") || base === "application/vnd.apple.mpegurl" || base === "application/x-mpegurl") {
    return "video"
  }

  if (base.startsWith("image/")) {
    return "image"
  }

  if (base === "application/pdf") {
    return "document"
  }

  return null
}

function mediaFromContentType(finalUrl: string, contentType: string): PreviewMedia | undefined {
  const base = baseContentType(contentType)
  if (!base) {
    return undefined
  }

  if (base.startsWith("video/") || base === "application/vnd.apple.mpegurl" || base === "application/x-mpegurl") {
    return {
      kind: "external_video",
      url: finalUrl,
      mimeType: base,
    }
  }

  if (base.startsWith("image/")) {
    return {
      kind: "photo",
      url: finalUrl,
      mimeType: base,
    }
  }

  if (base === "application/pdf") {
    return {
      kind: "document",
      url: finalUrl,
      mimeType: base,
    }
  }

  return undefined
}

function previewLayout(media: PreviewMedia) {
  const hasLargeMedia = media.kind === "external_video" || media.kind === "embed" || media.kind === "photo"
  return {
    hasLargeMedia,
    showLargeMedia: media.kind === "external_video" || media.kind === "embed",
  }
}

function mediaDuration(media: PreviewMedia | undefined): number | undefined {
  if (media?.kind === "external_video" || media?.kind === "embed") {
    return media.duration
  }
  return undefined
}

function firstNumberMeta(meta: ParsedHtml, keys: readonly string[]): number | undefined {
  const value = firstMeta(meta, keys)
  if (!value) {
    return undefined
  }

  const parsed = Number.parseFloat(value)
  return Number.isFinite(parsed) && parsed >= 0 ? Math.round(parsed) : undefined
}

function baseContentType(contentType: string): string {
  return contentType.split(";")[0]?.trim().toLowerCase() ?? ""
}

function fileTitle(url: string): string | undefined {
  const parsed = new URL(url)
  const lastPathPart = parsed.pathname.split("/").filter(Boolean).at(-1)
  if (!lastPathPart) {
    return hostLabel(url)
  }

  try {
    return decodeURIComponent(lastPathPart)
  } catch {
    return lastPathPart
  }
}
