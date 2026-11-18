/**
 * The render model for a message's media: what to draw in the first frame
 * (box and blurred preview) and what the media layer should fetch. Pure:
 * the view and the media scheduler do the loading.
 */

import type { MediaContent, MessageRow, PhotoInfo, VideoInfo } from "@inline/core-protocol"
import { documentRowModel, formatDuration, voiceRowModel, type DocumentRowModel, type FormatLocale, type VoiceRowModel } from "./files"
import { albumLayout, mediaDimensions, singleMediaBox, type AlbumLayout, type Box, type TimelineStyle } from "./layout"
import { strippedJpeg } from "./stripped"

export type VisualMediaModel = {
  readonly key: string
  /** `gif` is an animated video: muted, looping, no duration badge. */
  readonly kind: "photo" | "video" | "gif"
  readonly box: Box
  readonly sticker: boolean
  /** Draw without a bubble background: stickers, and PNG photos without a caption. */
  readonly noBubble: boolean
  /** A JPEG to show blurred until the real bytes arrive. Never for stickers. */
  readonly preview: Uint8Array | undefined
  /** The photo to load: the photo itself, or the video's thumbnail. */
  readonly photo: PhotoInfo | undefined
  readonly video: VideoInfo | undefined
  /** "1:15" for a video; undefined for GIFs or an unknown duration. */
  readonly durationText: string | undefined
}

export type MediaModel =
  | VisualMediaModel
  | (DocumentRowModel & { readonly key: string })
  | (VoiceRowModel & { readonly key: string })
  /** A nudge renders as its text (an emoji) without a bubble. */
  | { readonly kind: "nudge"; readonly key: string }

export type MediaModelOptions = {
  readonly availableWidth?: number
  readonly style?: TimelineStyle
  readonly locale?: FormatLocale
}

const previewOf = (photo: PhotoInfo | undefined): Uint8Array | undefined => strippedJpeg(photo?.stripped)

const mediaKey = (media: MediaContent): string => {
  switch (media.kind) {
    case "photo":
      return `photo:${media.photo.id}`
    case "video":
      return `video:${media.video.id}`
    case "document":
      return `document:${media.document.id}`
    case "voice":
      return `voice:${media.voice.id}`
    case "nudge":
      return "nudge"
  }
}

/** The media model for a row; undefined when it has no media. */
export const mediaModel = (
  row: Pick<MessageRow, "media" | "text">,
  options: MediaModelOptions = {},
): MediaModel | undefined => {
  const media = row.media
  if (!media) return undefined
  const key = mediaKey(media)
  const hasCaption = row.text.trim().length > 0
  switch (media.kind) {
    case "photo":
    case "video": {
      const sticker = media.sticker === true
      const box = singleMediaBox(media, {
        hasCaption,
        ...(options.availableWidth !== undefined ? { availableWidth: options.availableWidth } : {}),
        ...(options.style ? { style: options.style } : {}),
      }) ?? { width: 40, height: 40 }
      if (media.kind === "photo") {
        return {
          key,
          kind: "photo",
          box,
          sticker,
          noBubble: sticker || (media.photo.format === "png" && !hasCaption),
          preview: sticker ? undefined : previewOf(media.photo),
          photo: media.photo,
          video: undefined,
          durationText: undefined,
        }
      }
      const animated = media.video.animated === true
      return {
        key,
        kind: animated ? "gif" : "video",
        box,
        sticker,
        noBubble: sticker,
        preview: sticker ? undefined : previewOf(media.video.thumbnail),
        photo: media.video.thumbnail,
        video: media.video,
        durationText: !animated && media.video.duration > 0 ? formatDuration(media.video.duration) : undefined,
      }
    }
    case "document":
      return { ...documentRowModel(media.document, options.locale), key }
    case "voice":
      return { ...voiceRowModel(media.voice, options.locale), key }
    case "nudge":
      return { kind: "nudge", key }
  }
}

/**
 * The strip for grouped media messages (consecutive rows with one
 * `groupedId`), by the album rules. The Mac app has no grouped-message
 * mosaic; the web reuses its rich album strip. Undefined for fewer than 2 or
 * more than 10 visual items: render the rows on their own.
 */
export const groupedMediaLayout = (rows: readonly Pick<MessageRow, "media">[]): AlbumLayout | undefined => {
  if (rows.length < 2) return undefined
  if (!rows.every((row) => row.media?.kind === "photo" || row.media?.kind === "video")) return undefined
  return albumLayout(rows.map((row) => mediaDimensions(row.media)))
}
