/**
 * Link preview cards, by the Mac's rules (`InlineMac/Views/Message/Attachments/
 * URLPreviewAttachmentLayout.swift`, `InlineKit/.../UrlPreview.swift`,
 * `UrlPreviewDisplay.swift`).
 *
 * Every URL passes through `safeLink`. The card opens only a web link; a
 * preview whose URL is refused still shows its text, but nothing is clickable.
 * Media URLs (external video, embeds) must be web links too, and embeds are
 * never framed: the card shows the preview image and opens the link.
 */

import type { PhotoInfo, UrlPreviewAttachment, VideoInfo } from "@inline/core-protocol"
import { safeLink, type WebLink } from "../links"
import { formatDuration } from "../media/files"
import { photoDimensions, type Box, type TimelineStyle } from "../media/layout"
import { strippedJpeg } from "../media/stripped"

export const urlPreviewMetrics = {
  compactHeight: 40,
  compactAccentWidth: 3,
  compactThumbnail: 32,
  maxLargeMediaHeight: 300,
  bubbleMaxWidth: 260,
  minimalMaxWidth: 350,
  compactDescriptionLimit: 110,
  largeDescriptionLimit: 420,
  largeTitleLines: 2,
} as const

const providerNames: Readonly<Record<string, string>> = {
  loom: "Loom",
  youtube: "YouTube",
  vimeo: "Vimeo",
  github: "GitHub",
  figma: "Figma",
  notion: "Notion",
  linear: "Linear",
  sentry: "Sentry",
  x: "X",
  twitter: "X",
  reddit: "Reddit",
  tiktok: "TikTok",
  instagram: "Instagram",
  linkedin: "LinkedIn",
}

export type UrlPreviewModel = {
  readonly key: string
  readonly layout: "compact" | "large"
  /** X posts that are not articles: no title, the description is the body. */
  readonly style: "default" | "x"
  /** The link the card opens; undefined when the URL is not a safe web link. */
  readonly link: WebLink | undefined
  readonly title: string | undefined
  /** "youtube.com" or the provider's name. */
  readonly source: string | undefined
  /** Source (when it differs from the title), duration and description, joined with " • ". */
  readonly subtitle: string | undefined
  readonly description: string | undefined
  readonly author: { readonly name: string; readonly photo: PhotoInfo | undefined } | undefined
  readonly iconEmoji: string | undefined
  readonly media: UrlPreviewMediaModel | undefined
  /** Card width cap. */
  readonly maxWidth: number
}

export type UrlPreviewMediaModel = {
  readonly kind: "image" | "video"
  /** For large cards: width / height. */
  readonly aspect: number
  readonly photo: PhotoInfo | undefined
  readonly video: VideoInfo | undefined
  /** A remote stream to play in a `<video>` (web link only). */
  readonly stream: WebLink | undefined
  readonly preview: Uint8Array | undefined
  readonly durationText: string | undefined
}

const webOnly = (url: string | undefined): WebLink | undefined => {
  const link = safeLink(url)
  return link?.kind === "web" ? link : undefined
}

const hostOf = (value: string | undefined): string | undefined => {
  if (!value) return undefined
  const link = safeLink(value, { bareDomain: true })
  const host = link?.kind === "web" ? link.host : undefined
  return host?.toLowerCase().replace(/^www\./, "")
}

const clip = (value: string | undefined, limit: number): string | undefined => {
  if (value === undefined) return undefined
  const trimmed = value.trim()
  if (trimmed.length === 0) return undefined
  if (trimmed.length <= limit) return trimmed
  // Cut on a code point boundary.
  let end = limit
  const unit = trimmed.charCodeAt(end - 1)
  if (unit >= 0xd800 && unit <= 0xdbff) end -= 1
  return `${trimmed.slice(0, end)}...`
}

const nonBlank = (value: string | undefined): string | undefined => {
  const trimmed = value?.trim()
  return trimmed && trimmed.length > 0 ? trimmed : undefined
}

const isVideo = (preview: UrlPreviewAttachment): boolean =>
  preview.mediaType === "video" ||
  preview.media?.kind === "video" ||
  preview.media?.kind === "externalVideo" ||
  preview.media?.kind === "embed"

const primaryPhoto = (preview: UrlPreviewAttachment): PhotoInfo | undefined => {
  if (preview.media?.kind === "photo") return preview.media.photo
  if (preview.media?.kind === "video") return preview.media.video.thumbnail ?? preview.photo
  return preview.photo
}

/** The Mac's large-or-compact rule. */
export const prefersLargeMedia = (preview: UrlPreviewAttachment): boolean => {
  const layout = preview.layout
  if (layout?.showLargeMedia) return layout.hasLargeMedia
  if (layout && !layout.hasLargeMedia) return false
  return isVideo(preview) && primaryPhoto(preview) !== undefined
}

const aspectOf = (preview: UrlPreviewAttachment): number => {
  const media = preview.media
  if ((media?.kind === "externalVideo" || media?.kind === "embed") && media.width && media.height) {
    return media.width / media.height
  }
  if (media?.kind === "video" && media.video.width > 0 && media.video.height > 0) return media.video.width / media.video.height
  const photo: Box | undefined = photoDimensions(primaryPhoto(preview))
  if (photo) return photo.width / photo.height
  return 16 / 9
}

export type UrlPreviewOptions = {
  readonly style?: TimelineStyle
}

export const urlPreviewModel = (preview: UrlPreviewAttachment, options: UrlPreviewOptions = {}): UrlPreviewModel => {
  const link = webOnly(preview.url)
  const provider = preview.provider?.toLowerCase()
  const providerName = provider ? providerNames[provider] : undefined
  const source = providerName ?? hostOf(preview.displayUrl) ?? hostOf(preview.url) ?? nonBlank(preview.siteName)
  const large = prefersLargeMedia(preview)
  const xStyle = (provider === "x" || provider === "twitter") && preview.mediaType !== "article"
  const title = xStyle ? undefined : (nonBlank(preview.title) ?? source ?? nonBlank(preview.url))
  const description = clip(
    preview.description,
    large ? urlPreviewMetrics.largeDescriptionLimit : urlPreviewMetrics.compactDescriptionLimit,
  )
  const duration = isVideo(preview) && preview.duration ? formatDuration(preview.duration) : undefined
  const subtitleParts = [source !== title ? source : undefined, duration, large || xStyle ? undefined : description]
  const subtitle = subtitleParts.filter((part): part is string => part !== undefined).join(" • ")
  const photo = primaryPhoto(preview)
  const video = preview.media?.kind === "video" ? preview.media.video : undefined
  const stream = preview.media?.kind === "externalVideo" ? webOnly(preview.media.url) : undefined
  const showMedia = large ? photo !== undefined || stream !== undefined : photo !== undefined && preview.media?.kind !== "document"
  const media: UrlPreviewMediaModel | undefined =
    showMedia
        ? {
            kind: isVideo(preview) ? "video" : "image",
            aspect: aspectOf(preview),
            photo,
            video,
            stream,
            preview: strippedJpeg(photo?.stripped),
            durationText: duration,
          }
        : undefined
  const authorName = nonBlank(preview.author)
  return {
    key: `preview:${preview.id}`,
    layout: large && media ? "large" : "compact",
    style: xStyle ? "x" : "default",
    link,
    title,
    source,
    subtitle: subtitle.length > 0 ? subtitle : undefined,
    description,
    author:
      authorName && (provider === "youtube" || provider === "x" || provider === "twitter")
        ? { name: authorName, photo: preview.authorPhoto }
        : undefined,
    iconEmoji: nonBlank(preview.iconEmoji),
    media,
    maxWidth: options.style === "minimal" ? urlPreviewMetrics.minimalMaxWidth : urlPreviewMetrics.bubbleMaxWidth,
  }
}

/** Height of a large card's media at a card width: `min(width / aspect, 300)`. */
export const largePreviewMediaHeight = (media: UrlPreviewMediaModel, cardWidth: number): number =>
  Math.min(Math.round(cardWidth / (media.aspect > 0 ? media.aspect : 16 / 9)), urlPreviewMetrics.maxLargeMediaHeight)
