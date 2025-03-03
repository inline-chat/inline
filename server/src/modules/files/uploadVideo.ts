import { FileTypes, type UploadFileResult } from "@in/server/modules/files/types"
import { videos } from "@in/server/db/schema"
import { db } from "@in/server/db"
import { uploadFile } from "./uploadAFile"
import { getVideoMetadataAndValidate } from "@in/server/modules/files/metadata"

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
  // Get metadata and validate
  const metadata = await getVideoMetadataAndValidate(
    file,
    inputMetadata.width,
    inputMetadata.height,
    inputMetadata.duration,
  )
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
}
