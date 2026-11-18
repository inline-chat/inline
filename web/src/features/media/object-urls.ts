/**
 * Object URLs for media bytes the core hands the UI as `Blob` handles, and
 * for files the user attaches. Every URL made here is revoked by whoever made
 * it; `countingBlobUrls` keeps the live count (the lab shows it, tests check
 * it returns to zero).
 *
 * A `blob:` URL has the app's origin. Opened in a tab, an SVG or HTML blob
 * would run as the app, which owns the session. So a URL is only ever made
 * for a raster image, video or audio type on the allowlist; anything else is
 * retyped as `application/octet-stream` (a slice, no copy), which `<img>`,
 * `<video>` and `<audio>` still sniff and play and a tab only downloads.
 */

export type BlobUrlApi = {
  create(blob: Blob): string
  revoke(url: string): void
}

export const browserBlobUrls: BlobUrlApi = {
  create: (blob) => URL.createObjectURL(blob),
  revoke: (url) => URL.revokeObjectURL(url),
}

/** Types a media URL may carry as they are. Everything else becomes `application/octet-stream`. */
const SAFE_MEDIA_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/gif",
  "image/webp",
  "image/avif",
  "image/bmp",
  "image/heic",
  "image/heif",
  "video/mp4",
  "video/webm",
  "video/quicktime",
  "video/x-m4v",
  "audio/mpeg",
  "audio/mp4",
  "audio/aac",
  "audio/ogg",
  "audio/opus",
  "audio/wav",
  "audio/x-wav",
  "audio/webm",
])

export const OPAQUE_TYPE = "application/octet-stream"

/** The type a URL for these bytes may carry: the blob's own when it is a plain media type, else opaque. */
export const safeMediaType = (type: string | undefined): string => {
  const base = (type ?? "").split(";")[0]?.trim().toLowerCase() ?? ""
  return SAFE_MEDIA_TYPES.has(base) ? base : OPAQUE_TYPE
}

/** Whether a file type is a raster image the strip may preview through an object URL. */
export const isPreviewableImage = (type: string | undefined): boolean => {
  const safe = safeMediaType(type)
  return safe.startsWith("image/")
}

/** The blob as it may be given a URL: itself when its type is safe, else a retyped slice of it. */
export const safeBlob = (blob: Blob): Blob => {
  const type = safeMediaType(blob.type)
  return type === blob.type ? blob : blob.slice(0, blob.size, type)
}

export type CountingBlobUrls = BlobUrlApi & {
  /** URLs created and not yet revoked. */
  readonly live: () => number
  readonly created: () => number
  readonly revoked: () => number
  /** Listen for count changes (the lab's counter). */
  subscribe(listener: () => void): () => void
}

/**
 * Wraps an API with a live count. Revoking a URL it never made, or one it
 * already revoked, does not change the count (and is reported to `onStray`).
 */
export const countingBlobUrls = (
  api: BlobUrlApi = browserBlobUrls,
  onStray?: (url: string) => void,
): CountingBlobUrls => {
  const live = new Set<string>()
  const listeners = new Set<() => void>()
  let created = 0
  let revoked = 0
  const notify = () => {
    for (const listener of listeners) listener()
  }
  return {
    create: (blob) => {
      const url = api.create(blob)
      live.add(url)
      created += 1
      notify()
      return url
    },
    revoke: (url) => {
      if (!live.delete(url)) {
        onStray?.(url)
        return
      }
      api.revoke(url)
      revoked += 1
      notify()
    },
    live: () => live.size,
    created: () => created,
    revoked: () => revoked,
    subscribe: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
  }
}
