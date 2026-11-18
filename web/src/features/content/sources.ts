/**
 * Where media bytes come from. A row carries no fetch state (`chat-ui`
 * `media/variants.ts`): the media layer turns a photo, video or voice note
 * into a URL. Views ask through `MediaSources` and only ever put the result in
 * an element's own `src`; nothing in the content views fetches.
 *
 * `cdnMediaSources` is the stand-in until the media scheduler and registry
 * exist (`timeline-and-composer.md`, "Media in the timeline"): it uses the
 * signed `cdnUrl` the row carries, after the link allowlist, and never
 * refreshes an expired one. The real layer implements the same interface
 * with `pending` while bytes download into an object URL.
 */

import { type Box, photoVariantFor, safeLink } from "@inline/chat-ui"
import type { AttachmentId, MessageState, PhotoInfo, VideoInfo, VoiceInfo } from "@inline/core-protocol"
import type { ChatID, MessageID } from "@inline/ids"
import { type ReadSignal, signal } from "@inline/reactive"

export type MediaSourceState =
  /** `progress`: received over total bytes (0 to 1) while downloading, when the layer knows it. */
  | { readonly status: "pending"; readonly progress?: number }
  | { readonly status: "ready"; readonly url: string }
  /** Nothing to load: no stored size, or a URL the allowlist refused. */
  | { readonly status: "failed" }

/** Something a view hands a DOM element to, and that lets go when the cleanup runs (`useElement`). */
export type ElementPart = { attach(element: Element): () => void }

export type MediaSource = {
  readonly state: ReadSignal<MediaSourceState>
  /** Ask again after a load failed in the element (an expired signed URL, a network error). */
  retry(): void
  /**
   * The view hands the media box to this part while it shows the source. A
   * layer that loads on demand holds the bytes while some box is attached
   * (and may watch the box's visibility); without it the source is static.
   */
  readonly part?: ElementPart
}

/**
 * The message a piece of media belongs to, so a media layer can ask the core
 * for its bytes. Built by `RowContent.mediaOwner(row)`, which keeps one object
 * per distinct value (memoized views compare it by identity).
 */
export type MediaOwner = {
  readonly chatId: ChatID
  /** Absent until the server assigns one (a send from this device). */
  readonly messageId: MessageID | undefined
  /** A send from this device that is not on the server yet: its local attachment (`MessageRow.upload`). */
  readonly attachmentId: AttachmentId | undefined
  readonly clientKey: string | undefined
  readonly state: MessageState
}

/** How a send's upload is going. `fraction` is sent over total bytes (0 to 1), absent before the first progress. */
export type UploadSourceState = {
  readonly phase: "pending" | "staged" | "uploading" | "processing" | "complete" | "failed" | "canceled"
  readonly fraction: number | undefined
}

/** A send from this device with an attachment: its upload's progress, and the row's two actions. */
export type UploadSource = {
  readonly state: ReadSignal<UploadSourceState>
  /** Hold the progress while the control showing it is attached. */
  readonly part?: ElementPart
  /** "Cancel Upload": cancel the send (the Mac's words). */
  cancel(): void
  /** "Resend" a failed send. */
  resend(): void
}

/**
 * The app's media layer. Each method is called while rendering, so it must be
 * cheap and should return the same `MediaSource` for the same input.
 *
 * `owner` names the message whose `media` this is (the message's own photo,
 * video, document or voice note); `thumbnail` says the photo is a video's or
 * document's thumbnail. Media that is not the message's own (block images,
 * link previews) is asked for without an owner.
 */
export type MediaSources = {
  /** A photo (or a video's or document's thumbnail) for a box in CSS pixels. */
  photo(photo: PhotoInfo, box: Box, owner?: MediaOwner, thumbnail?: boolean): MediaSource
  video(video: VideoInfo, owner?: MediaOwner): MediaSource
  voice(voice: VoiceInfo, owner?: MediaOwner): MediaSource
  /** The upload of a send from this device (`owner.attachmentId`), or undefined when there is none. */
  upload?(owner: MediaOwner): UploadSource | undefined
}

const failedState: MediaSourceState = { status: "failed" }

/** A source that never changes. */
export const constantSource = (state: MediaSourceState): MediaSource => ({ state: signal(state), retry: () => {} })

const failedSource = constantSource(failedState)

/** A URL the content views may load: a web link (`http:` or `https:`) after the allowlist. */
export const mediaUrl = (url: string | undefined): string | undefined => {
  const link = safeLink(url)
  return link?.kind === "web" ? link.href : undefined
}

export type CdnMediaSourcesOptions = {
  /** Device pixel ratio for choosing a photo size. Default `globalThis.devicePixelRatio` or 1. */
  readonly pixelRatio?: () => number
}

/** Sources from the rows' signed `cdnUrl`s. Cached per input object, so a render asks once. */
export const cdnMediaSources = (options: CdnMediaSourcesOptions = {}): MediaSources => {
  const pixelRatio = options.pixelRatio ?? (() => globalThis.devicePixelRatio ?? 1)
  const photos = new WeakMap<PhotoInfo, Map<string, MediaSource>>()
  const others = new WeakMap<object, MediaSource>()
  const fromUrl = (url: string | undefined): MediaSource => {
    const safe = mediaUrl(url)
    return safe ? constantSource({ status: "ready", url: safe }) : failedSource
  }
  const cached = (key: object, url: string | undefined): MediaSource => {
    let source = others.get(key)
    if (!source) {
      source = fromUrl(url)
      others.set(key, source)
    }
    return source
  }
  return {
    photo(photo, box) {
      const variant = photoVariantFor(photo, box, pixelRatio())
      const url = variant?.size.cdnUrl
      const key = `${variant?.size.type ?? ""}:${url ?? ""}`
      let byVariant = photos.get(photo)
      if (!byVariant) {
        byVariant = new Map()
        photos.set(photo, byVariant)
      }
      let source = byVariant.get(key)
      if (!source) {
        source = fromUrl(url)
        byVariant.set(key, source)
      }
      return source
    },
    video: (video) => cached(video, video.cdnUrl),
    voice: (voice) => cached(voice, voice.cdnUrl),
  }
}
