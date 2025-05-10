import { getPhotoMetadataAndValidate } from "@in/server/modules/files/metadata"
import { FileTypes, type UploadFileResult } from "@in/server/modules/files/types"
import { photos, photoSizes } from "@in/server/db/schema"
import { db } from "@in/server/db"
import { uploadFile } from "./uploadAFile"
import { Log } from "@in/server/utils/log"

const log = new Log("modules/files/uploadPhoto")

export async function uploadPhoto(file: File, context: { userId: number }): Promise<UploadFileResult> {
  try {
    log.info("Starting photo upload", { fileSize: file.size, userId: context.userId })

    // Get metadata and validate
    let metadata
    try {
      metadata = await getPhotoMetadataAndValidate(file)
      log.info("Photo metadata validated successfully", {
        width: metadata.width,
        height: metadata.height,
        mimeType: metadata.mimeType,
      })
    } catch (error) {
      log.error("Failed to validate photo metadata", { error })
      throw new Error("Invalid photo file")
    }

    const { dbFile, fileUniqueId } = await uploadFile(file, FileTypes.PHOTO, metadata, context)

    // Generate thumbhash and store that
    // Upload thumbnails...
    // TODO: Implement this

    // Save photo metadata
    const format = metadata.mimeType === "image/jpeg" ? "jpeg" : "png"
    let photo
    try {
      ;[photo] = await db
        .insert(photos)
        .values({
          format,
          width: metadata.width,
          height: metadata.height,
          date: new Date(),
        })
        .returning()

      if (!photo) {
        throw new Error("No photo returned from database")
      }
      log.info("Photo metadata saved successfully", { photoId: photo.id })
    } catch (error) {
      log.error("Failed to save photo metadata", { error, fileUniqueId })
      throw new Error("Failed to save photo metadata")
    }

    let photoSizes_
    try {
      photoSizes_ = await db
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
        throw new Error("No photo sizes returned from database")
      }
      log.info("Photo sizes saved successfully", { photoId: photo.id })
    } catch (error) {
      log.error("Failed to save photo sizes", { error, photoId: photo.id })
      throw new Error("Failed to save photo sizes")
    }

    log.info("Photo upload completed successfully", {
      fileUniqueId,
      photoId: photo.id,
      userId: context.userId,
    })
    return { fileUniqueId, photoId: photo.id }
  } catch (error) {
    log.error("Photo upload failed", { error, userId: context.userId })
    throw error
  }
}

function generateThumbnails(file: File, fileUniqueId: string, prefix: string) {
  // TODO: Implement this
}

function generateThumbhash(file: File, fileUniqueId: string, prefix: string) {
  // TODO: Implement this
}
