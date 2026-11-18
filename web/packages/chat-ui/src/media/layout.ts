/**
 * Boxes for media in the timeline, so a row has its final size in its first
 * frame, before any bytes arrive. Sizes are CSS pixels.
 *
 * The rules are the Mac app's (`InlineMac/Views/MessageList/MessageSizeCalculator.swift`
 * `calculatePhotoSize`, `RichBlockLayoutPlanner.swift` images and albums,
 * `MacTheme/Theme.swift`):
 *
 * - Single photo or video, bubble style: aspect-fit into a square box whose
 *   side is `min(320, available width)`, at least 40. Never upscaled, except
 *   captioned media in bubble style, which fills the box width. Missing or
 *   zero dimensions give 40 x 40.
 * - Minimal style: at most 350 wide and 300 high.
 * - Sticker: the same rule with a 120 box, no bubble.
 * - Rich image block: at most `min(available, 420)` x 420, never upscaled;
 *   unknown dimensions are 240 x 180.
 * - Album (rich block, and grouped media messages on the web): one row,
 *   126 high, items `clamp(126 x ratio, 96, 220)` wide with 6 between them;
 *   ratio clamped to 0.2...5, 4/3 when unknown; 1 to 10 items.
 */

import type { MediaContent, PhotoInfo } from "@inline/core-protocol"
import { bestPhotoSize } from "./variants"

export type Box = { readonly width: number; readonly height: number }

export const mediaMetrics = {
  /** Bubble style: the longest side of a photo or video. */
  maxSide: 320,
  stickerMaxSide: 120,
  minSide: 40,
  /** The message column's maximum width in bubble style (`messageMaxWidth`). */
  messageMaxWidth: 420,
  minimalMaxWidth: 350,
  minimalMaxHeight: 300,
  richImageMaxSide: 420,
  richImageUnknown: { width: 240, height: 180 },
  albumHeight: 126,
  albumSpacing: 6,
  albumMinItemWidth: 96,
  albumMaxItemWidth: 220,
  albumMaxItems: 10,
  albumDefaultRatio: 4 / 3,
  albumMinRatio: 0.2,
  albumMaxRatio: 5,
  /** Corner radius of a media bubble (`messageBubbleCornerRadius - 1`). */
  cornerRadius: 13,
} as const

export type MediaFitOptions = {
  /** Width available to the message content. Default: the bubble maximum (420). */
  readonly availableWidth?: number
  /** Longest side. Default 320 (120 for stickers). */
  readonly maxSide?: number
  /** Box height; default a square box (`maxSide`). */
  readonly maxHeight?: number
  /** Fill the box width even past the media's own size (captioned bubble media). */
  readonly upscale?: boolean
}

const finitePositive = (value: number | undefined): number =>
  typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0

/** The Mac's `calculatePhotoSize`: aspect-fit into the box, 40 at least. */
export const fitMedia = (width: number, height: number, options: MediaFitOptions = {}): Box => {
  const min = mediaMetrics.minSide
  const available = finitePositive(options.availableWidth) || mediaMetrics.messageMaxWidth
  const maxWidth = Math.max(min, Math.min(options.maxSide ?? mediaMetrics.maxSide, Math.ceil(available)))
  const maxHeight = Math.max(min, options.maxHeight ?? maxWidth)
  const w = finitePositive(width)
  const h = finitePositive(height)
  if (w === 0 || h === 0) return { width: min, height: min }
  const aspect = w / h
  const fit = Math.min(maxWidth / w, maxHeight / h)
  const scale = options.upscale ? fit : Math.min(1, fit)
  let boxWidth = Math.ceil(w * scale)
  let boxHeight = Math.ceil(boxWidth / aspect)
  if (boxHeight > maxHeight) {
    boxHeight = Math.ceil(h * scale)
    boxWidth = Math.ceil(boxHeight * aspect)
  }
  return { width: boxWidth, height: boxHeight }
}

/** The source size of a photo: its best stored size. */
export const photoDimensions = (photo: PhotoInfo | undefined): Box | undefined => {
  const size = bestPhotoSize(photo)
  return size && size.width > 0 && size.height > 0 ? { width: size.width, height: size.height } : undefined
}

/** Source dimensions of visual media: the media's own, else its thumbnail's. */
export const mediaDimensions = (media: MediaContent | undefined): Box | undefined => {
  if (!media) return undefined
  if (media.kind === "photo") return photoDimensions(media.photo)
  if (media.kind === "video") {
    const { width, height } = media.video
    if (width > 0 && height > 0) return { width, height }
    return photoDimensions(media.video.thumbnail)
  }
  return undefined
}

export type TimelineStyle = "bubble" | "minimal"

export type SingleMediaLayoutOptions = {
  readonly availableWidth?: number
  readonly style?: TimelineStyle
  /** The message has text under the media. */
  readonly hasCaption?: boolean
}

/** The box for a message's photo, video, sticker or GIF. Undefined for other media. */
export const singleMediaBox = (media: MediaContent | undefined, options: SingleMediaLayoutOptions = {}): Box | undefined => {
  if (!media || (media.kind !== "photo" && media.kind !== "video")) return undefined
  const source = mediaDimensions(media) ?? { width: 0, height: 0 }
  if (media.sticker) {
    return fitMedia(source.width, source.height, {
      ...(options.availableWidth !== undefined ? { availableWidth: options.availableWidth } : {}),
      maxSide: mediaMetrics.stickerMaxSide,
    })
  }
  if (options.style === "minimal") {
    return fitMedia(source.width, source.height, {
      ...(options.availableWidth !== undefined ? { availableWidth: options.availableWidth } : {}),
      maxSide: mediaMetrics.minimalMaxWidth,
      maxHeight: mediaMetrics.minimalMaxHeight,
    })
  }
  return fitMedia(source.width, source.height, {
    ...(options.availableWidth !== undefined ? { availableWidth: options.availableWidth } : {}),
    upscale: options.hasCaption === true,
  })
}

/** A rich image block's box: at most `min(available, 420)` x 420, never upscaled. */
export const richImageBox = (dimensions: Box | undefined, availableWidth?: number): Box => {
  const maxWidth = Math.min(finitePositive(availableWidth) || mediaMetrics.richImageMaxSide, mediaMetrics.richImageMaxSide)
  const maxHeight = mediaMetrics.richImageMaxSide
  const source =
    dimensions && dimensions.width > 0 && dimensions.height > 0 ? dimensions : mediaMetrics.richImageUnknown
  const scale = Math.min(1, maxWidth / source.width, maxHeight / source.height)
  return { width: Math.max(1, Math.floor(source.width * scale)), height: Math.max(1, Math.floor(source.height * scale)) }
}

export type AlbumItemBox = Box & { readonly x: number }

export type AlbumLayout = {
  readonly items: readonly AlbumItemBox[]
  /** Total width of the strip; it scrolls horizontally when wider than the column. */
  readonly width: number
  readonly height: number
}

/** The album strip: one row, fixed height. Undefined for 0 or more than 10 items (fall back). */
export const albumLayout = (dimensions: readonly (Box | undefined)[]): AlbumLayout | undefined => {
  if (dimensions.length === 0 || dimensions.length > mediaMetrics.albumMaxItems) return undefined
  const height = mediaMetrics.albumHeight
  const items: AlbumItemBox[] = []
  let x = 0
  for (const dimension of dimensions) {
    const ratio =
      dimension && dimension.width > 0 && dimension.height > 0
        ? Math.min(mediaMetrics.albumMaxRatio, Math.max(mediaMetrics.albumMinRatio, dimension.width / dimension.height))
        : mediaMetrics.albumDefaultRatio
    const width = Math.min(mediaMetrics.albumMaxItemWidth, Math.max(mediaMetrics.albumMinItemWidth, height * ratio))
    if (items.length > 0) x += mediaMetrics.albumSpacing
    items.push({ x, width, height })
    x += width
  }
  return { items, width: x, height }
}
