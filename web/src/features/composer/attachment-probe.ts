/**
 * What the composer learns about a photo or video before handing it to the
 * core: its size, a video's length, and the tiny preview a sending row
 * draws (`attachFile.preview`, `width`, `height`, `duration`), so a sending
 * photo is not a blank box and a sending video keeps its height when it
 * completes. Framework-free; the browser parts sit behind `AttachmentProber`
 * so tests inject a fake.
 *
 * - **Preview.** The server's stripped thumbnail, matched: at most 40 px on
 *   the long side, never enlarged, flattened on white, JPEG quality 20
 *   (`server/src/modules/files/strippedThumbnail.ts`:
 *   `STRIPPED_THUMBNAIL_MAX_DIMENSION = 40`, `quality: 20`, `flatten` white),
 *   so this client's sending rows look like every client's sent ones. The
 *   Mac makes no preview of its own; it shows the server's `s` size. A
 *   complete JPEG (the contract's `preview`), not the header-stripped form.
 *   An encoder that does not return `image/jpeg` gives no preview (engines
 *   differ in what a canvas returns).
 * - **Off the first frame.** Probing starts a task after the file is added
 *   (the strip shows the attachment first) and runs one file at a time
 *   (`serialProber`): at most one decoded image is alive, and it is closed
 *   as soon as the preview is drawn.
 * - **Bounded.** A video gets `VIDEO_PROBE_TIMEOUT_MS` for its metadata and
 *   first frame; anything the browser cannot decode gives what it has (or
 *   nothing) and the attachment goes on without it.
 */

export type AttachmentProbe = {
  readonly width?: number
  readonly height?: number
  /** Seconds, for video. */
  readonly duration?: number
  /** A complete tiny JPEG. */
  readonly preview?: Uint8Array
}

export type ProbeKind = "image" | "video"

export type AttachmentProber = (file: Blob, kind: ProbeKind) => Promise<AttachmentProbe>

/** The server's stripped thumbnail: `STRIPPED_THUMBNAIL_MAX_DIMENSION`. */
export const PREVIEW_MAX_SIDE = 40
/** The server's stripped thumbnail: sharp `quality: 20`. */
export const PREVIEW_QUALITY = 0.2
/** How long a video may take to give its metadata and a first frame. */
export const VIDEO_PROBE_TIMEOUT_MS = 4_000
/** How long the composer waits for any probe before handing the file to the core without it. */
export const ATTACHMENT_PROBE_TIMEOUT_MS = 6_000

/**
 * The Mac's rule for an image that would make a poor photo message: very
 * wide or tall (sides more than 20:1), or very small (both sides under
 * 50 px) goes as a file (`apple/InlineMac/Views/Compose/GlassComposeAppKit.swift`
 * `shouldSendAsFile`, also in `LegacyComposeAppKit.swift`).
 */
export const sendsAsFile = (width: number, height: number): boolean => {
  if (!(width > 0) || !(height > 0)) return false
  const ratio = Math.max(width / height, height / width)
  if (ratio > 20) return true
  return width < 50 && height < 50
}

/** The preview's size for a source of `width` by `height`: inside 40 px, never enlarged. */
export const previewSize = (width: number, height: number): { width: number; height: number } => {
  const scale = Math.min(1, PREVIEW_MAX_SIDE / Math.max(width, height, 1))
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) }
}

/** One probe at a time, in order, across every chat that shares the returned prober. */
export const serialProber = (prober: AttachmentProber): AttachmentProber => {
  let tail: Promise<unknown> = Promise.resolve()
  return (file, kind) => {
    const run = tail.then(
      () => prober(file, kind),
      () => prober(file, kind),
    )
    tail = run.then(
      () => undefined,
      () => undefined,
    )
    return run
  }
}

// ---------------------------------------------------------------------------
// Browser

type Canvas2D = {
  fillStyle: string | CanvasGradient | CanvasPattern
  fillRect(x: number, y: number, w: number, h: number): void
  drawImage(image: CanvasImageSource, dx: number, dy: number, dw: number, dh: number): void
}

/** Draw `source` at the preview size on white and encode it as JPEG; undefined when the engine cannot. */
export const encodePreview = async (source: CanvasImageSource, width: number, height: number): Promise<Uint8Array | undefined> => {
  const size = previewSize(width, height)
  let blob: Blob | null = null
  try {
    if (typeof OffscreenCanvas === "function") {
      const canvas = new OffscreenCanvas(size.width, size.height)
      const context = canvas.getContext("2d") as Canvas2D | null
      if (!context) return undefined
      context.fillStyle = "#fff"
      context.fillRect(0, 0, size.width, size.height)
      context.drawImage(source, 0, 0, size.width, size.height)
      blob = await canvas.convertToBlob({ type: "image/jpeg", quality: PREVIEW_QUALITY })
    } else if (typeof document !== "undefined") {
      const canvas = document.createElement("canvas")
      canvas.width = size.width
      canvas.height = size.height
      const context = canvas.getContext("2d") as Canvas2D | null
      if (!context) return undefined
      context.fillStyle = "#fff"
      context.fillRect(0, 0, size.width, size.height)
      context.drawImage(source, 0, 0, size.width, size.height)
      blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", PREVIEW_QUALITY))
    }
  } catch {
    return undefined
  }
  if (!blob || blob.type !== "image/jpeg") return undefined
  return new Uint8Array(await blob.arrayBuffer())
}

const probeImage = async (file: Blob): Promise<AttachmentProbe> => {
  if (typeof createImageBitmap !== "function") return {}
  let bitmap: ImageBitmap | undefined
  try {
    // EXIF orientation applied (`imageOrientation: "from-image"` is the default).
    bitmap = await createImageBitmap(file)
    const { width, height } = bitmap
    const preview = await encodePreview(bitmap, width, height)
    return { width, height, ...(preview ? { preview } : {}) }
  } catch {
    return {}
  } finally {
    bitmap?.close()
  }
}

const probeVideo = (file: Blob): Promise<AttachmentProbe> => {
  if (typeof document === "undefined" || typeof URL.createObjectURL !== "function") return Promise.resolve({})
  return new Promise<AttachmentProbe>((resolve) => {
    const video = document.createElement("video")
    const url = URL.createObjectURL(file)
    let found: { width?: number; height?: number; duration?: number } = {}
    let done = false
    const finish = (preview?: Uint8Array) => {
      if (done) return
      done = true
      clearTimeout(timer)
      video.removeAttribute("src")
      video.load()
      URL.revokeObjectURL(url)
      resolve({ ...found, ...(preview ? { preview } : {}) })
    }
    const timer = setTimeout(() => finish(), VIDEO_PROBE_TIMEOUT_MS)
    video.muted = true
    video.playsInline = true
    video.preload = "auto"
    video.addEventListener("error", () => finish(), { once: true })
    video.addEventListener(
      "loadedmetadata",
      () => {
        const duration = Number.isFinite(video.duration) && video.duration > 0 ? Math.round(video.duration) : undefined
        found = {
          ...(video.videoWidth > 0 ? { width: video.videoWidth, height: video.videoHeight } : {}),
          ...(duration !== undefined ? { duration } : {}),
        }
        if (video.videoWidth === 0) {
          finish()
          return
        }
        // A frame a little in, past a black first frame, never past the end.
        video.currentTime = Math.min(0.1, (video.duration || 0) / 2)
      },
      { once: true },
    )
    video.addEventListener(
      "seeked",
      () => {
        void encodePreview(video, video.videoWidth, video.videoHeight).then(finish, () => finish())
      },
      { once: true },
    )
    video.src = url
  })
}

/** Decodes in the page: `createImageBitmap` for images, a `<video>` for video. */
export const browserAttachmentProber: AttachmentProber = (file, kind) => (kind === "image" ? probeImage(file) : probeVideo(file))
