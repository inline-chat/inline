import {
  DEFAULT_DESCRIPTION_LENGTH,
  DEFAULT_MAX_HTML_BYTES,
  DEFAULT_MAX_REDIRECTS,
  DEFAULT_SITE_NAME_LENGTH,
  DEFAULT_TIMEOUT_MS,
  DEFAULT_TITLE_LENGTH,
  DEFAULT_USER_AGENT,
} from "../constants.js"
import { isBlockedIp } from "../filters.js"
import { parseJsonObject } from "../json.js"
import { defaultLookup, fetchWithRedirects, readResponseText, readResponseTextPrefix } from "../network.js"
import { normalizeMetadataUrl } from "../normalize.js"
import { asFiniteNumber, asString, cleanField, cleanMultilineField, stripTags } from "../text.js"
import type { FetchUrlPreviewOptions, PreviewMedia, PreviewMediaType, UrlPreviewResult } from "../types.js"
import { previewLayout, textCardLayout } from "../layout.js"
import type { UrlPreviewProvider } from "./types.js"

const X_SYNDICATION_URL = "https://cdn.syndication.twimg.com/tweet-result"
const X_SYNDICATION_TOKEN = "x"
const X_NOTE_TWEET_TEXT_LIMIT = 4_000

type XMediaPreview = {
  imageUrl?: string
  mediaType?: PreviewMediaType
  media?: PreviewMedia
  duration?: number
}

export const xProvider: UrlPreviewProvider = {
  name: "x",
  canHandle: isXStatusUrl,
  fetch: fetchXPreview,
}

export function isXStatusUrl(url: string): boolean {
  return xStatusId(url) != null
}

async function fetchXPreview(
  url: string,
  options: FetchUrlPreviewOptions,
): Promise<UrlPreviewResult | null> {
  const id = xStatusId(url)
  if (!id) {
    return null
  }

  const endpoint = new URL(X_SYNDICATION_URL)
  endpoint.searchParams.set("id", id)
  endpoint.searchParams.set("token", X_SYNDICATION_TOKEN)
  endpoint.searchParams.set("lang", "en")

  const response = await fetchXEndpoint(endpoint, options)
  if (!response?.ok) {
    return null
  }

  const text = await readResponseText(response, 256 * 1024).catch(() => null)
  const data = text ? objectValue(parseJsonObject(text)) : null
  if (!data || asString(data["__typename"]) !== "Tweet") {
    return null
  }

  const user = objectValue(data["user"])
  const author = cleanField(asString(user?.["name"]), options.maxSiteNameLength ?? DEFAULT_SITE_NAME_LENGTH)
  const screenName = cleanField(asString(user?.["screen_name"]), 80)
  const rawTweetText = tweetTextWithoutAttachedMediaUrls(data)
  const resolvedTweetText = (await fetchXNoteTweetText(id, data, rawTweetText, options)) ?? rawTweetText
  const tweetText = cleanMultilineField(
    resolvedTweetText,
    options.maxDescriptionLength ?? DEFAULT_DESCRIPTION_LENGTH,
  )
  const authorPhotoUrl = normalizeXProfileImageUrl(asString(user?.["profile_image_url_https"]))
  const media = tweetMedia(data)
  const title = cleanField(tweetTitle(author, screenName), options.maxTitleLength ?? DEFAULT_TITLE_LENGTH)
  const layout = media.media ? previewLayout(media.media) : textCardLayout("x", Boolean(tweetText))

  if (!title && !tweetText && !authorPhotoUrl && !media.imageUrl) {
    return null
  }

  return {
    url,
    finalUrl: url,
    siteName: "X",
    title: title ?? undefined,
    description: tweetText ?? undefined,
    imageUrl: media.imageUrl,
    duration: media.duration,
    mediaType: media.mediaType,
    provider: "x",
    author: author ?? undefined,
    authorPhotoUrl,
    media: media.media,
    layout,
  }
}

async function fetchXEndpoint(endpoint: URL, options: FetchUrlPreviewOptions): Promise<Response | null> {
  const lookup = options.lookup ?? defaultLookup
  const addresses = await lookup(endpoint.hostname).catch(() => [])
  if (addresses.length === 0 || addresses.some((address) => isBlockedIp(address.address))) {
    return null
  }

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs ?? DEFAULT_TIMEOUT_MS)

  try {
    return await (options.fetchImpl ?? fetch)(endpoint.toString(), {
      redirect: "manual",
      signal: controller.signal,
      headers: {
        Accept: "application/json",
        "User-Agent": options.userAgent ?? DEFAULT_USER_AGENT,
      },
    })
  } catch {
    return null
  } finally {
    clearTimeout(timeout)
  }
}

async function fetchXNoteTweetText(
  id: string,
  data: Record<string, unknown>,
  compatibilityText: string | undefined,
  options: FetchUrlPreviewOptions,
): Promise<string | null> {
  if (!hasNoteTweet(data) || !compatibilityText) {
    return null
  }

  const html = await fetchXStatusHtml(id, options)
  if (!html) {
    return null
  }

  const cleanedCompatibilityText = cleanMultilineField(compatibilityText, X_NOTE_TWEET_TEXT_LIMIT)
  if (!cleanedCompatibilityText) {
    return null
  }

  const candidates = extractLoggedOutTweetTexts(html)
    .filter((candidate) => textExtendsCompatibilityText(candidate, cleanedCompatibilityText))
    .sort((a, b) => b.length - a.length)

  return candidates[0] ?? null
}

async function fetchXStatusHtml(id: string, options: FetchUrlPreviewOptions): Promise<string | null> {
  const statusUrl = `https://x.com/i/status/${id}`
  try {
    const response = await fetchWithRedirects(statusUrl, {
      fetchImpl: options.fetchImpl ?? fetch,
      lookup: options.lookup ?? defaultLookup,
      timeoutMs: options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
      maxRedirects: options.maxRedirects ?? DEFAULT_MAX_REDIRECTS,
      userAgent: options.userAgent ?? DEFAULT_USER_AGENT,
      accept: "text/html,application/xhtml+xml",
    })

    if (!response.response.ok || !isXStatusUrl(response.finalUrl)) {
      return null
    }

    const contentType = response.response.headers.get("content-type")?.toLowerCase() ?? ""
    if (contentType && !contentType.includes("text/html") && !contentType.includes("application/xhtml+xml")) {
      await response.response.body?.cancel().catch(() => undefined)
      return null
    }

    return await readResponseTextPrefix(response.response, options.maxHtmlBytes ?? DEFAULT_MAX_HTML_BYTES)
  } catch {
    return null
  }
}

function extractLoggedOutTweetTexts(html: string): string[] {
  const texts = new Set<string>()

  for (const match of html.matchAll(/<div\b(?=[^>]*\bdir\s*=\s*(?:"auto"|'auto'))([^>]*)>([\s\S]*?)<\/div>/gi)) {
    const className = tagClassName(match[1] ?? "")
    if (!className || !hasClassName(className, "whitespace-pre-wrap") || !hasClassName(className, "text-body")) {
      continue
    }

    const text = cleanMultilineField(htmlFragmentText(match[2] ?? ""), X_NOTE_TWEET_TEXT_LIMIT)
    if (text) {
      texts.add(text)
    }
  }

  return Array.from(texts)
}

function htmlFragmentText(html: string): string {
  return stripTags(html.replace(/<br\s*\/?>/gi, "\n")) ?? ""
}

function tagClassName(attributes: string): string | null {
  const match = attributes.match(/\bclass\s*=\s*(?:"([^"]*)"|'([^']*)')/i)
  return (match?.[1] ?? match?.[2])?.trim() ?? null
}

function hasClassName(className: string, expected: string): boolean {
  return className.split(/\s+/).includes(expected)
}

function textExtendsCompatibilityText(candidate: string, compatibilityText: string): boolean {
  const comparableCandidate = compactTweetText(candidate)
  const comparableCompatibility = compactTweetText(compatibilityText)
  if (!comparableCandidate || comparableCandidate.length <= comparableCompatibility.length) {
    return false
  }

  if (comparableCandidate.startsWith(comparableCompatibility)) {
    return true
  }

  const prefixLength = Math.min(180, Math.floor(comparableCompatibility.length * 0.75))
  const prefix = comparableCompatibility.slice(0, prefixLength)
  return prefix.length >= 40 && comparableCandidate.startsWith(prefix)
}

function compactTweetText(value: string): string {
  return value.replace(/\s+/g, " ").trim()
}

function hasNoteTweet(data: Record<string, unknown>): boolean {
  return data["note_tweet"] != null
}

function xStatusId(value: string): string | null {
  try {
    const parsed = new URL(value)
    const host = parsed.hostname.toLowerCase().replace(/^www\./, "")
    if (!isXHost(host)) {
      return null
    }

    return parsed.pathname.match(/^\/[^/]+\/status(?:es)?\/(\d+)/)?.[1] ?? null
  } catch {
    return null
  }
}

function isXHost(host: string): boolean {
  return host === "x.com" || host.endsWith(".x.com") || host === "twitter.com" || host.endsWith(".twitter.com")
}

function tweetTitle(author: string | null, screenName: string | null): string | null {
  if (author && screenName) {
    return `${author} (@${screenName}) on X`
  }

  if (author) {
    return `${author} on X`
  }

  return null
}

function tweetMedia(data: Record<string, unknown>): XMediaPreview {
  const details = arrayValue(data["mediaDetails"]).map(objectValue).filter((item) => item != null)
  const media = details[0]
  if (!media) {
    return {}
  }

  const imageUrl = normalizeMetadataUrl(asString(media["media_url_https"]), "https://x.com") ?? undefined
  const width = originalWidth(media)
  const height = originalHeight(media)
  const type = asString(media["type"])?.toLowerCase()

  if (type === "photo" && imageUrl) {
    const photo: PreviewMedia = {
      kind: "photo",
      url: imageUrl,
      width,
      height,
    }

    return {
      imageUrl,
      mediaType: "image",
      media: photo,
    }
  }

  if (type === "video" || type === "animated_gif") {
    const video = xVideo(media)
    if (!video) {
      return {
        imageUrl,
        mediaType: "video",
      }
    }

    return {
      imageUrl,
      mediaType: "video",
      duration: video.duration,
      media: {
        kind: "external_video",
        url: video.url,
        mimeType: video.mimeType,
        width,
        height,
        duration: video.duration,
      },
    }
  }

  return imageUrl ? { imageUrl } : {}
}

function tweetTextWithoutAttachedMediaUrls(data: Record<string, unknown>): string | undefined {
  const text = asString(data["text"])
  if (!text) {
    return undefined
  }

  const mediaUrls = attachedMediaUrls(data)
  if (mediaUrls.length === 0) {
    return text
  }

  let output = text
  for (const url of mediaUrls) {
    output = output.split(url).join("")
  }

  return output
    .split("\n")
    .map((line) => line.replace(/[ \t]+$/g, ""))
    .join("\n")
    .replace(/[ \t]{2,}/g, " ")
    .trim()
}

function attachedMediaUrls(data: Record<string, unknown>): string[] {
  const urls = new Set<string>()
  const entities = objectValue(data["entities"])
  for (const item of arrayValue(entities?.["media"]).map(objectValue)) {
    const url = asString(item?.["url"])
    if (url) {
      urls.add(url)
    }
  }
  for (const item of arrayValue(data["mediaDetails"]).map(objectValue)) {
    const url = asString(item?.["url"])
    if (url) {
      urls.add(url)
    }
  }
  return Array.from(urls)
}

function xVideo(media: Record<string, unknown>): { url: string; mimeType?: string; duration?: number } | null {
  const info = objectValue(media["video_info"])
  const variants = arrayValue(info?.["variants"]).map(objectValue).filter((item) => item != null)
  const mp4 = variants
    .filter((item) => asString(item["content_type"]) === "video/mp4" && asString(item["url"]))
    .sort((a, b) => (asFiniteNumber(b["bitrate"]) ?? 0) - (asFiniteNumber(a["bitrate"]) ?? 0))[0]
  const fallback = mp4 ?? variants.find((item) => asString(item["url"]))
  const url = normalizeMetadataUrl(asString(fallback?.["url"]), "https://x.com")
  if (!url) {
    return null
  }

  const durationMs = asFiniteNumber(info?.["duration_millis"])
  return {
    url,
    mimeType: asString(fallback?.["content_type"]) ?? undefined,
    duration: durationMs == null ? undefined : Math.max(1, Math.round(durationMs / 1_000)),
  }
}

function originalWidth(media: Record<string, unknown>): number | undefined {
  return asFiniteNumber(objectValue(media["original_info"])?.["width"]) ?? undefined
}

function originalHeight(media: Record<string, unknown>): number | undefined {
  return asFiniteNumber(objectValue(media["original_info"])?.["height"]) ?? undefined
}

function normalizeXProfileImageUrl(value: string | undefined): string | undefined {
  const url = normalizeMetadataUrl(value, "https://x.com")
  return url?.replace(/_normal(\.[a-z0-9]+)(\?|$)/i, "_200x200$1$2")
}

function objectValue(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null
}

function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}
