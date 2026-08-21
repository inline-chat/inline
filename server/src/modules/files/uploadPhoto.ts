import { getPhotoMetadataAndValidate } from "@in/server/modules/files/metadata"
import { FileTypes, type UploadFileResult } from "@in/server/modules/files/types"
import { files, photos, photoSizes } from "@in/server/db/schema"
import { db } from "@in/server/db"
import { encryptBinary } from "@in/server/modules/encryption/encryption"
import { generateStrippedThumbnail } from "@in/server/modules/files/strippedThumbnail"
import {
  createFileObjectIdentity,
  type FileObjectIdentity,
  uploadFileObject,
} from "./uploadAFile"
import { InlineError } from "@in/server/types/errors"
import { toArrayBufferBackedBytes } from "@in/server/utils/arrayBuffer"
import { Log } from "@in/server/utils/log"
import sharp from "sharp"

const log = new Log("modules/files/uploadPhoto")

export type UploadPhotoOptions = {
  identity?: FileObjectIdentity
  onIdentityPrepared?: (identity: FileObjectIdentity) => Promise<void>
}

export async function uploadPhoto(
  file: File,
  context: { userId: number },
  options: UploadPhotoOptions = {},
): Promise<UploadFileResult> {
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
      log.error("Failed to validate photo metadata", {
        error,
        fileName: file.name,
        fileSize: file.size,
        mimeType: file.type,
      })
      if (error instanceof InlineError) {
        throw error
      }
      throw new Error("Invalid photo file", { cause: error as Error })
    }

    const normalized = await normalizePhotoUpload(file, metadata)
    const identity = options.identity
      ?? createFileObjectIdentity(FileTypes.PHOTO, normalized.metadata.extension)
    await options.onIdentityPrepared?.(identity)
    const prepared = await uploadFileObject(
      normalized.file,
      FileTypes.PHOTO,
      normalized.metadata,
      context,
      identity,
    )
    const { fileUniqueId } = prepared

    const strippedThumbnail = await generateStrippedThumbnail(normalized.file).catch((error) => {
      log.warn("Failed to generate stripped thumbnail", {
        error,
        fileUniqueId,
        userId: context.userId,
        fileName: normalized.file.name,
      })
      return null
    })

    const encryptedStrippedThumbnail = strippedThumbnail ? encryptBinary(strippedThumbnail.bytes) : null

    // Persist the complete photo graph atomically. The object-store write is
    // intentionally outside PostgreSQL; callers that need compensation must
    // durably own `identity.path` before this function begins that write.
    const format = normalized.metadata.mimeType === "image/jpeg" ? "jpeg" : "png"
    try {
      const photoId = await db.transaction(async (tx) => {
        const [dbFile] = await tx.insert(files).values(prepared.dbFile).returning()
        if (!dbFile) throw new Error("No file returned from database")

        const [photo] = await tx.insert(photos).values({
          format,
          width: normalized.metadata.width,
          height: normalized.metadata.height,
          stripped: encryptedStrippedThumbnail?.encrypted ?? null,
          strippedIv: encryptedStrippedThumbnail?.iv ?? null,
          strippedTag: encryptedStrippedThumbnail?.authTag ?? null,
          date: new Date(),
        }).returning()

        if (!photo) throw new Error("No photo returned from database")
        const insertedSizes = await tx.insert(photoSizes).values({
          fileId: dbFile.id,
          photoId: photo.id,
          size: "f",
          width: normalized.metadata.width,
          height: normalized.metadata.height,
        }).returning({ id: photoSizes.id })

        if (insertedSizes.length === 0) throw new Error("No photo sizes returned from database")
        return photo.id
      })
      log.info("Photo graph saved successfully", { photoId, fileUniqueId })
      log.info("Photo upload completed successfully", {
        fileUniqueId,
        photoId,
        userId: context.userId,
      })
      return { fileUniqueId, photoId }
    } catch (error) {
      log.error("Failed to save photo graph", { error, fileUniqueId })
      throw new Error("Failed to save photo graph", { cause: error as Error })
    }
  } catch (error) {
    log.error("Photo upload failed", {
      error,
      userId: context.userId,
      fileName: file.name,
      fileSize: file.size,
      mimeType: file.type,
    })
    throw error
  }
}

export async function normalizePhotoUpload(
  file: File,
  metadata: Awaited<ReturnType<typeof getPhotoMetadataAndValidate>>,
): Promise<{
  file: File
  metadata: Awaited<ReturnType<typeof getPhotoMetadataAndValidate>>
}> {
  if (metadata.mimeType !== "image/webp") {
    return { file, metadata }
  }

  const png = await sharp(await file.arrayBuffer()).png().toBuffer()
  const normalizedFile = new File([toArrayBufferBackedBytes(png)], pngFileName(metadata.fileName), {
    type: "image/png",
  })
  const normalizedMetadata = await getPhotoMetadataAndValidate(normalizedFile)
  return { file: normalizedFile, metadata: normalizedMetadata }
}

function pngFileName(fileName: string): string {
  const trimmed = fileName.trim() || "photo.webp"
  if (trimmed.includes(".")) {
    return trimmed.replace(/\.[^.]+$/, ".png")
  }
  return `${trimmed}.png`
}
