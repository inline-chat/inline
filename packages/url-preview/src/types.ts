export type PreviewProvider = "generic" | "loom" | "youtube" | "notion" | (string & {})
export type PreviewMediaType = "article" | "image" | "video" | "document" | "embed"

/** Source media detected by the URL preview fetch pipeline. */
export type PreviewMedia =
  | PreviewPhotoMedia
  | PreviewExternalVideoMedia
  | PreviewEmbedMedia
  | PreviewDocumentMedia

/** Image media that the server can download and store as a Photo. */
export type PreviewPhotoMedia = {
  /** Discriminator for image media. */
  kind: "photo"

  /** Validated public source URL for the image. */
  url: string

  /** MIME type from metadata or headers when known. */
  mimeType?: string

  /** Image width in pixels when known. */
  width?: number

  /** Image height in pixels when known. */
  height?: number
}

/** Direct remote video that is playable but not stored as an Inline Video yet. */
export type PreviewExternalVideoMedia = {
  /** Discriminator for direct remote video media. */
  kind: "external_video"

  /** Validated public source URL for the video stream. */
  url: string

  /** MIME type from metadata or headers when known. */
  mimeType?: string

  /** Video width in pixels when known. */
  width?: number

  /** Video height in pixels when known. */
  height?: number

  /** Video duration in seconds when known. */
  duration?: number
}

/** Provider/player embed that clients may open or render specially. */
export type PreviewEmbedMedia = {
  /** Discriminator for provider/player embeds. */
  kind: "embed"

  /** Validated provider or player URL. */
  url: string

  /** Provider/player type such as iframe, player, or video. */
  embedType?: string

  /** Embed width in pixels when known. */
  width?: number

  /** Embed height in pixels when known. */
  height?: number

  /** Media duration in seconds when known. */
  duration?: number
}

/** Downloadable or document-like media detected from content type. */
export type PreviewDocumentMedia = {
  /** Discriminator for document media. */
  kind: "document"

  /** Validated public source URL for the document. */
  url: string

  /** MIME type from metadata or headers when known. */
  mimeType?: string
}

/** Layout hints derived by the fetch pipeline for clients to adapt. */
export type PreviewLayout = {
  /** True when media metadata supports a larger rendering. */
  hasLargeMedia: boolean

  /** True when clients should prefer a larger media rendering. */
  showLargeMedia: boolean
}

export type FetchImpl = (input: string | URL, init?: RequestInit) => Promise<Response>
export type LookupAddress = { address: string; family: number }
export type LookupFn = (hostname: string) => Promise<LookupAddress[]>

export type UrlPreviewResult = {
  /** Normalized canonical URL represented by the preview. */
  url: string

  /** Final URL after safe redirects. */
  finalUrl: string

  /** Human-readable site or provider name. */
  siteName?: string

  /** Preview title, trimmed by the configured bound. */
  title?: string

  /** Preview description, trimmed by the configured bound. */
  description?: string

  /** Poster or thumbnail image URL, if any. */
  imageUrl?: string

  /** Duration summary in seconds for compatibility clients. */
  duration?: number

  /** Compatibility media summary derived from media or explicit metadata. */
  mediaType?: PreviewMediaType

  /** Stable provider key that produced the preview. */
  provider: PreviewProvider

  /** Author, channel, account, or publisher when known. */
  author?: string

  /** Typed primary media source for the preview. */
  media?: PreviewMedia

  /** Layout hints derived from metadata and media dimensions. */
  layout?: PreviewLayout
}

export type FetchUrlPreviewOptions = {
  fetchImpl?: FetchImpl
  lookup?: LookupFn
  timeoutMs?: number
  maxRedirects?: number
  maxHtmlBytes?: number
  maxTitleLength?: number
  maxDescriptionLength?: number
  maxSiteNameLength?: number
  userAgent?: string
}

export type FetchBinaryOptions = {
  fetchImpl?: FetchImpl
  lookup?: LookupFn
  timeoutMs?: number
  maxRedirects?: number
  maxBytes?: number
  allowedContentTypes?: readonly string[]
  userAgent?: string
}

export type FetchBinaryResult = {
  bytes: Uint8Array
  contentType: string
  finalUrl: string
}
