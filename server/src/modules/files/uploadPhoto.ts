import { getPhotoMetadataAndValidate } from "@in/server/modules/files/metadata"
import { FileTypes, type UploadFileResult } from "@in/server/modules/files/types"
import { photos, photoSizes } from "@in/server/db/schema"
import { db } from "@in/server/db"
import { uploadFile } from "./uploadAFile"
import { Log } from "@in/server/utils/log"

export async function uploadPhoto(file: File, context: { userId: number }): Promise<UploadFileResult> {
  // Get metadata and validate
  const metadata = await getPhotoMetadataAndValidate(file)

  const { dbFile, fileUniqueId } = await uploadFile(file, FileTypes.PHOTO, metadata, context)

  // Generate thumbhash and store that
  // Upload thumbnails...
  // TODO: Implement this

  // Save photo metadata
  const format = metadata.mimeType === "image/jpeg" ? "jpeg" : "png"
  const [photo] = await db
    .insert(photos)
    .values({
      format,
      width: metadata.width,
      height: metadata.height,
      date: new Date(),
    })
    .returning()

  if (!photo) {
    throw new Error("Failed to save photo to DB")
  }

  const photoSizes_ = await db
    .insert(photoSizes)
    .values({
      fileId: dbFile.id,
      photoId: photo.id,
      size: "f",
      width: metadata.width,
      height: metadata.height,
    })
    .returning()

  if (photoSizes_.length === 0) {
    throw new Error("Failed to save photo sizes to DB")
  }

  return { fileUniqueId, photoId: photo.id }
}

function generateThumbnails(file: File, fileUniqueId: string, prefix: string) {
  // TODO: Implement this
}

function generateThumbhash(file: File, fileUniqueId: string, prefix: string) {
  // TODO: Implement this
}
