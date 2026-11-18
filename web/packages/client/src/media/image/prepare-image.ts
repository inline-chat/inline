import {
  JPEG_MAX_DIMENSION,
  JPEG_MIN_COMPRESSION_RATIO,
  JPEG_QUALITY,
  PNG_MAX_DIMENSION,
  PNG_MIN_COMPRESSION_RATIO,
  TINY_PREVIEW_MAX_DIMENSION,
  TINY_PREVIEW_QUALITY,
} from "../constants"

/**
 * `photo`: compress like `ImageCompressor` before sending as a photo.
 * `original`: send the bytes as they are (as a file); only measure and make a preview.
 */
export type ImagePurpose = "photo" | "original"

export type PreparedImage =
  | {
    readonly kind: "image"
    readonly blob: Blob
    /** The type of `blob`, checked; the server takes only JPEG and PNG photos. */
    readonly mimeType: string
    readonly width: number
    readonly height: number
    /** A tiny JPEG for the optimistic row's first frame. */
    readonly tinyPreview?: Uint8Array
    /** False when the original was kept (already small, or compression did not pay). */
    readonly reencoded: boolean
  }
  /** Not a photo this client can prepare: send it as a document. */
  | { readonly kind: "document"; readonly reason: "undecodable" | "animated" | "unsupported" }

export interface ImagePreparer {
  prepareImage(blob: Blob, purpose: ImagePurpose): Promise<PreparedImage>
}

export type DecodedImage = {
  readonly width: number
  readonly height: number
  close(): void
}

/** The platform part: decode and encode. Workers in browsers have it; Node does not. */
export interface ImageCodec {
  decode(blob: Blob): Promise<DecodedImage | undefined>
  encode(image: DecodedImage, target: { width: number; height: number; type: string; quality?: number }): Promise<Blob>
}

const PHOTO_TYPES = new Set(["image/jpeg", "image/png"])
const ANIMATED_TYPES = new Set(["image/gif"])

export type ImagePlan = {
  readonly type: "image/jpeg" | "image/png"
  readonly quality?: number
  readonly width: number
  readonly height: number
  readonly minimumRatio: number
  /** The original may be sent when compression does not pay. */
  readonly originalUsable: boolean
}

/** `ImageCompressionOptions.defaultPhoto` for everything but PNG, which keeps `.defaultPNG`. */
export const planImage = (sourceType: string, width: number, height: number): ImagePlan => {
  const png = sourceType === "image/png"
  const maxDimension = png ? PNG_MAX_DIMENSION : JPEG_MAX_DIMENSION
  const ratio = Math.min(1, maxDimension / width, maxDimension / height)
  return {
    type: png ? "image/png" : "image/jpeg",
    quality: png ? undefined : JPEG_QUALITY,
    width: Math.max(1, Math.round(width * ratio)),
    height: Math.max(1, Math.round(height * ratio)),
    minimumRatio: png ? PNG_MIN_COMPRESSION_RATIO : JPEG_MIN_COMPRESSION_RATIO,
    originalUsable: PHOTO_TYPES.has(sourceType),
  }
}

const tinyDimensions = (width: number, height: number) => {
  const ratio = Math.min(1, TINY_PREVIEW_MAX_DIMENSION / width, TINY_PREVIEW_MAX_DIMENSION / height)
  return { width: Math.max(1, Math.round(width * ratio)), height: Math.max(1, Math.round(height * ratio)) }
}

/**
 * Image preparation over a codec. The logic (limits, the type check, keeping
 * the original when compression does not pay) is here and tested with a fake
 * codec; the codec is the only platform code.
 */
export const createImagePreparer = (codec: ImageCodec): ImagePreparer => ({
  async prepareImage(blob, purpose) {
    const sourceType = blob.type.toLowerCase()
    if (ANIMATED_TYPES.has(sourceType)) return { kind: "document", reason: "animated" }
    const decoded = await codec.decode(blob).catch(() => undefined)
    if (!decoded || decoded.width < 1 || decoded.height < 1) {
      decoded?.close()
      return { kind: "document", reason: "undecodable" }
    }
    try {
      const tinyPreview = await makeTinyPreview(codec, decoded)
      if (purpose === "original") {
        return { kind: "image", blob, mimeType: sourceType, width: decoded.width, height: decoded.height, tinyPreview, reencoded: false }
      }
      const plan = planImage(sourceType, decoded.width, decoded.height)
      const original = { kind: "image" as const, blob, mimeType: sourceType, width: decoded.width, height: decoded.height, tinyPreview, reencoded: false }
      const encoded = await codec.encode(decoded, { width: plan.width, height: plan.height, type: plan.type, quality: plan.quality }).catch(() => undefined)
      // Engines differ in what a canvas returns: never trust the requested type.
      if (!encoded || encoded.type !== plan.type) {
        return plan.originalUsable ? original : { kind: "document", reason: "unsupported" }
      }
      // `compressionNotEffective`: when the result is not clearly smaller, the original goes.
      if (plan.originalUsable && encoded.size / blob.size > plan.minimumRatio) return original
      return { kind: "image", blob: encoded, mimeType: plan.type, width: plan.width, height: plan.height, tinyPreview, reencoded: true }
    } finally {
      decoded.close()
    }
  },
})

const makeTinyPreview = async (codec: ImageCodec, decoded: DecodedImage): Promise<Uint8Array | undefined> => {
  const size = tinyDimensions(decoded.width, decoded.height)
  const blob = await codec.encode(decoded, { ...size, type: "image/jpeg", quality: TINY_PREVIEW_QUALITY }).catch(() => undefined)
  if (!blob || blob.type !== "image/jpeg") return undefined
  return new Uint8Array(await blob.arrayBuffer())
}

/**
 * The browser codec: `createImageBitmap` and `OffscreenCanvas`, both available
 * in dedicated workers.
 *
 * UNVERIFIED: never run in a browser. Check orientation handling
 * (`imageOrientation: "from-image"`), color space, HEIC (Safari only),
 * and what `convertToBlob` returns for each requested type in Chromium,
 * WebKit and Firefox.
 */
export const browserImageCodec: ImageCodec = {
  async decode(blob) {
    if (typeof createImageBitmap !== "function") return undefined
    const bitmap = await createImageBitmap(blob, { imageOrientation: "from-image" })
    return {
      width: bitmap.width,
      height: bitmap.height,
      close: () => bitmap.close(),
      bitmap,
    } as DecodedImage & { bitmap: ImageBitmap }
  },
  async encode(image, target) {
    const bitmap = (image as DecodedImage & { bitmap?: ImageBitmap }).bitmap
    if (!bitmap || typeof OffscreenCanvas !== "function") throw new Error("No canvas in this context")
    const canvas = new OffscreenCanvas(target.width, target.height)
    const context = canvas.getContext("2d")
    if (!context) throw new Error("No 2D context")
    context.imageSmoothingEnabled = true
    context.imageSmoothingQuality = "high"
    if (target.type === "image/jpeg") {
      // JPEG has no alpha: paint transparent areas white, as a photo would show them.
      context.fillStyle = "#fff"
      context.fillRect(0, 0, target.width, target.height)
    }
    context.drawImage(bitmap, 0, 0, target.width, target.height)
    return await canvas.convertToBlob({ type: target.type, quality: target.quality })
  },
}

export const browserImagePreparer: ImagePreparer = createImagePreparer(browserImageCodec)
