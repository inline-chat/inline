import { FileTypes, type UploadFileResult } from "@in/server/modules/files/types"
import { videos } from "@in/server/db/schema"
import { db } from "@in/server/db"
import { uploadFile } from "./uploadAFile"
import { getVideoMetadataAndValidate } from "@in/server/modules/files/metadata"
import { Log } from "@in/server/utils/log"

const log = new Log("modules/files/uploadVideo")

interface VideoMetadata {
  width: number
  height: number
  duration: number
  photoId?: bigint // Optional thumbnail photo ID
}

export async function uploadVideo(
  file: File,
  inputMetadata: VideoMetadata,
  context: { userId: number },
): Promise<UploadFileResult> {
  try {
    // Get metadata and validate
    const metadata = await getVideoMetadataAndValidate(
      file,
      inputMetadata.width,
      inputMetadata.height,
      inputMetadata.duration,
    )

    if (
      metadata.width !== inputMetadata.width ||
      metadata.height !== inputMetadata.height ||
      metadata.duration !== inputMetadata.duration
    ) {
      log.warn("Video metadata mismatch detected", {
        userId: context.userId,
        inputWidth: inputMetadata.width,
        inputHeight: inputMetadata.height,
        inputDuration: inputMetadata.duration,
        validatedWidth: metadata.width,
        validatedHeight: metadata.height,
        validatedDuration: metadata.duration,
        fileName: file.name,
        fileSize: file.size,
        mimeType: file.type,
      })
    }

    const { dbFile, fileUniqueId } = await uploadFile(file, FileTypes.VIDEO, metadata, context)

    // Save video metadata
    const [video] = await db
      .insert(videos)
      .values({
        fileId: dbFile.id,
        width: metadata.width,
        height: metadata.height,
        duration: metadata.duration,
        photoId: inputMetadata.photoId,
        date: new Date(),
      })
      .returning()

    if (!video) {
      throw new Error("Failed to save video to DB")
    }

    return { fileUniqueId, videoId: video.id }
  } catch (error) {
    log.error("Video upload failed", {
      error,
      userId: context.userId,
      width: inputMetadata.width,
      height: inputMetadata.height,
      duration: inputMetadata.duration,
      hasThumbnailId: inputMetadata.photoId != null,
      fileName: file.name,
      fileSize: file.size,
      mimeType: file.type,
    })
    throw error
  }
}
