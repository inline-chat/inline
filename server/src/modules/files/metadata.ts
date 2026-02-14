import { ApiError, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import sharp from "sharp"

const log = new Log("modules/files/metadata")
const validPhotoMimeTypes = ["image/jpeg", "image/png", "image/gif"]
const validPhotoExtensions = ["jpg", "jpeg", "png", "gif"]
const maxFileSize = 40_000_000 // 40MB

// Get the width and height of a photo and validate the dimensions
export const getPhotoMetadataAndValidate = async (
  file: File,
): Promise<{ width: number; height: number; mimeType: string; fileName: string; extension: string }> => {
  const fileName = file.name || "photo"
  const size = file.size
  const mimeType = file.type.trim()
  let extension = fileName.split(".").pop()?.toLowerCase()

  if (size === 0) {
    throw badRequest("Uploaded photo is empty")
  }

  if (size > maxFileSize) {
    throw new InlineError(InlineError.ApiError.FILE_TOO_LARGE)
  }

  if (!mimeType) {
    throw badRequest("Uploaded photo is missing MIME type")
  }

  // Validate the extension
  if (extension && !validPhotoExtensions.includes(extension)) {
    throw new InlineError(InlineError.ApiError.PHOTO_INVALID_EXTENSION)
  }
  extension = extension ?? "jpg"

  // Validate the mime type
  if (!mimeType.startsWith("image/")) {
    throw new InlineError(InlineError.ApiError.PHOTO_INVALID_TYPE)
  }

  if (!validPhotoMimeTypes.includes(mimeType)) {
    throw new InlineError(InlineError.ApiError.PHOTO_INVALID_TYPE)
  }

  let width: number | undefined
  let height: number | undefined

  // Get original metadata including orientation
  try {
    const pipeline = sharp(await file.arrayBuffer())
    const originalMetadata = await pipeline.metadata()

    // Swap dimensions if needed based on EXIF orientation
    const shouldSwap =
      originalMetadata.orientation && originalMetadata.orientation >= 5 && originalMetadata.orientation <= 8
    width = shouldSwap ? originalMetadata.height : originalMetadata.width
    height = shouldSwap ? originalMetadata.width : originalMetadata.height

    // Continue processing with auto-orientation
    await pipeline.rotate().toBuffer() // Ensures image data is properly oriented
  } catch (error) {
    log.error("Photo metadata extraction failed", {
      error,
      fileName,
      fileSize: size,
      mimeType,
      extension,
    })
    throw new InlineError(ApiError.PHOTO_INVALID_TYPE)
  }

  // Validate the dimensions
  if (typeof width !== "number" || typeof height !== "number") {
    throw new InlineError(ApiError.PHOTO_INVALID_DIMENSIONS)
  }

  if (width + height > 15000) {
    // TODO: Reduce
    throw new InlineError(InlineError.ApiError.PHOTO_INVALID_DIMENSIONS)
  }

  const ratio = Math.max(width / height, height / width)
  if (ratio > 20) {
    throw new InlineError(InlineError.ApiError.PHOTO_INVALID_DIMENSIONS)
  }

  return { width, height, mimeType, fileName, extension }
}

const validVideoMimeTypes = ["video/mp4"]
const validVideoExtensions = ["mp4"]
const maxVideoFileSize = 200_000_000 // 200MB

export const getVideoMetadataAndValidate = async (
  file: File,
  width: number,
  height: number,
  duration: number,
): Promise<{
  width: number
  height: number
  duration: number
  mimeType: string
  fileName: string
  extension: string
}> => {
  // TODO: Implement video metadata extraction using ffmpeg or similar
  // For now, we'll do basic file validation

  let fileName = file.name || "video"
  let size = file.size
  let mimeType = file.type.trim()
  let extension = fileName.split(".").pop()?.toLowerCase()

  if (size === 0) {
    throw badRequest("Uploaded video is empty")
  }

  if (!mimeType) {
    throw badRequest("Uploaded video is missing MIME type")
  }

  if (!Number.isInteger(width) || width <= 0 || !Number.isInteger(height) || height <= 0) {
    log.error("Invalid video dimensions", { width, height, duration, fileName, size, mimeType })
    throw new InlineError(InlineError.ApiError.VIDEO_INVALID_DIMENSIONS)
  }

  if (!Number.isInteger(duration) || duration < 0) {
    log.error("Invalid video duration", { width, height, duration, fileName, size, mimeType })
    throw badRequest("Invalid video duration: expected integer >= 0")
  }

  // Validate the extension
  if (extension && !validVideoExtensions.includes(extension)) {
    throw new InlineError(InlineError.ApiError.VIDEO_INVALID_EXTENSION)
  }
  extension = extension ?? "mp4"

  // Validate file size
  if (size > maxVideoFileSize) {
    throw new InlineError(InlineError.ApiError.FILE_TOO_LARGE)
  }

  // Validate the mime type
  if (!mimeType.startsWith("video/")) {
    throw new InlineError(InlineError.ApiError.VIDEO_INVALID_TYPE)
  }

  if (!validVideoMimeTypes.includes(mimeType)) {
    throw new InlineError(InlineError.ApiError.VIDEO_INVALID_TYPE)
  }

  // TODO: Extract actual video metadata using ffmpeg

  return { width, height, duration, mimeType, fileName, extension }
}

const maxDocumentFileSize = 200_000_000 // 200MB

export const getDocumentMetadataAndValidate = async (
  file: File,
): Promise<{ mimeType: string; fileName: string; extension: string }> => {
  // it contains %20 stuff so we need to decode it
  let fileName = decodeFileName(file.name, "document")

  let size = file.size
  let mimeType = file.type.trim()
  let extension = fileName.split(".").pop()?.toLowerCase()

  if (size === 0) {
    throw badRequest("Uploaded document is empty")
  }

  if (!mimeType) {
    throw badRequest("Uploaded document is missing MIME type")
  }

  if (!extension) {
    throw new InlineError(InlineError.ApiError.DOCUMENT_INVALID_EXTENSION)
  }

  // Validate file size
  if (size > maxDocumentFileSize) {
    throw new InlineError(InlineError.ApiError.FILE_TOO_LARGE)
  }

  return { mimeType, fileName, extension }
}

function decodeFileName(fileName: string | undefined, fallback: string): string {
  const raw = fileName?.trim()
  if (!raw) return fallback
  try {
    return decodeURIComponent(raw)
  } catch (error) {
    log.error("Failed to decode filename", { error, raw })
    return raw
  }
}

function badRequest(description: string): InlineError {
  const error = new InlineError(ApiError.BAD_REQUEST)
  error.description = description
  return error
}
