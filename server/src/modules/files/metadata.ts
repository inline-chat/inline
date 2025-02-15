import { ApiError, InlineError } from "@in/server/types/errors"
import sharp from "sharp"

const validPhotoMimeTypes = ["image/jpeg", "image/png", "image/gif"]
const validPhotoExtensions = ["jpg", "jpeg", "png", "gif"]
const maxFileSize = 40_000_000 // 40MB

// Get the width and height of a photo and validate the dimensions
export const getPhotoMetadataAndValidate = async (
  file: File,
): Promise<{ width: number; height: number; mimeType: string; fileName: string; extension: string }> => {
  // Get original metadata including orientation
  const pipeline = sharp(await file.arrayBuffer())
  const originalMetadata = await pipeline.metadata()

  // Swap dimensions if needed based on EXIF orientation
  const shouldSwap =
    originalMetadata.orientation && originalMetadata.orientation >= 5 && originalMetadata.orientation <= 8
  const width = shouldSwap ? originalMetadata.height : originalMetadata.width
  const height = shouldSwap ? originalMetadata.width : originalMetadata.height

  // Continue processing with auto-orientation
  await pipeline.rotate().toBuffer() // Ensures image data is properly oriented

  // TODO: Filter of the sensitive characters
  let fileName = file.name
  let size = file.size
  let mimeType = file.type
  let extension = fileName.split(".").pop()

  // Validate the extension
  if (extension && !validPhotoExtensions.includes(extension)) {
    throw new InlineError(InlineError.ApiError.PHOTO_INVALID_EXTENSION)
  }
  extension = extension ?? "jpg"

  if (size > 40_000_000) {
    throw new InlineError(InlineError.ApiError.FILE_TOO_LARGE)
  }

  // Validate the dimensions
  if (typeof width !== "number" || typeof height !== "number") {
    throw new InlineError(ApiError.PHOTO_INVALID_DIMENSIONS)
  }

  if (width + height > 10000) {
    throw new InlineError(InlineError.ApiError.PHOTO_INVALID_DIMENSIONS)
  }

  const ratio = Math.max(width / height, height / width)
  if (ratio > 20) {
    throw new InlineError(InlineError.ApiError.PHOTO_INVALID_DIMENSIONS)
  }

  // Validate the mime type
  if (!mimeType.startsWith("image/")) {
    throw new InlineError(InlineError.ApiError.PHOTO_INVALID_TYPE)
  }

  if (!validPhotoMimeTypes.includes(mimeType)) {
    throw new InlineError(InlineError.ApiError.PHOTO_INVALID_TYPE)
  }

  return { width, height, mimeType, fileName, extension }
}
