import { MAX_FILE_SIZE } from "@in/server/config"
import { uploadDocument } from "@in/server/modules/files/uploadDocument"
import { uploadPhoto } from "@in/server/modules/files/uploadPhoto"
import type { UploadFileResult } from "@in/server/modules/files/types"
import { uploadVideo } from "@in/server/modules/files/uploadVideo"
import { uploadVoice } from "@in/server/modules/files/uploadVoice"
import { ApiError, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { validateUploadFileMetadata } from "./uploadFileMetadata"

const log = new Log("methods/uploadFile")

export interface UploadFileOperationInput {
  readonly type: "photo" | "video" | "document" | "voice"
  readonly file?: File | null | undefined
  readonly thumbnail?: File | null | undefined
  readonly width?: string | null | undefined
  readonly height?: string | null | undefined
  readonly duration?: string | null | undefined
  readonly isAnimated?: string | null | undefined
  readonly hasAudio?: string | null | undefined
  readonly waveform?: string | null | undefined
}

export interface UploadFileOperationContext {
  readonly currentUserId: number
  readonly currentSessionId: number
  readonly ip: string | undefined
}

export const uploadFileOperation = async (
  input: UploadFileOperationInput,
  context: UploadFileOperationContext,
): Promise<UploadFileResult> => {
  const requestDiagnostics = describeUploadRequest(input, context)
  log.info("Starting file upload request", requestDiagnostics)

  const file = requireUploadFile(input.file)

  const {
    width,
    height,
    duration,
    isAnimated,
    hasAudio,
    waveform,
  } = validateUploadFileMetadata(input)

  if (input.thumbnail?.size === 0) {
    throw uploadBadRequest("Uploaded thumbnail is empty")
  }
  if (input.thumbnail && input.thumbnail.size > MAX_FILE_SIZE) {
    throw new InlineError(ApiError.FILE_TOO_LARGE)
  }
  if (input.thumbnail != null && !input.thumbnail.type?.trim()) {
    throw uploadBadRequest("Uploaded thumbnail is missing MIME type")
  }

  let result: UploadFileResult
  let uploadedThumbnailId: number | undefined

  switch (input.type) {
    case "photo":
      result = await uploadPhoto(file, { userId: context.currentUserId })
      break
    case "video":
      if (input.thumbnail) {
        const thumbResult = await uploadPhoto(input.thumbnail, { userId: context.currentUserId })
        uploadedThumbnailId = thumbResult.photoId
      }
      result = await uploadVideo(
        file,
        {
          width: width ?? 1280,
          height: height ?? 720,
          duration: duration ?? 0,
          photoId: uploadedThumbnailId ? BigInt(uploadedThumbnailId) : undefined,
          isAnimated: isAnimated ?? false,
          hasAudio,
        },
        { userId: context.currentUserId },
      )
      break
    case "document":
      if (input.thumbnail) {
        const thumbResult = await uploadPhoto(input.thumbnail, { userId: context.currentUserId })
        uploadedThumbnailId = thumbResult.photoId
      }
      result = await uploadDocument(
        file,
        uploadedThumbnailId ? BigInt(uploadedThumbnailId) : undefined,
        { userId: context.currentUserId },
      )
      break
    case "voice":
      result = await uploadVoice(
        file,
        {
          duration: duration ?? 0,
          waveform: waveform ?? new Uint8Array(),
        },
        { userId: context.currentUserId },
      )
      break
  }

  log.info("File upload completed successfully", {
    ...requestDiagnostics,
    fileUniqueId: result.fileUniqueId,
  })

  return {
    fileUniqueId: result.fileUniqueId,
    photoId: result.photoId ?? uploadedThumbnailId,
    videoId: result.videoId,
    documentId: result.documentId,
    voiceId: result.voiceId,
  }
}

function requireUploadFile(file: File | null | undefined): File {
  if (!file) {
    throw uploadBadRequest("Missing multipart file field `file`")
  }
  if (file.size === 0) {
    throw uploadBadRequest("Uploaded file is empty")
  }
  if (file.size > MAX_FILE_SIZE) {
    throw new InlineError(ApiError.FILE_TOO_LARGE)
  }
  return file
}

function uploadBadRequest(description: string): InlineError {
  const error = new InlineError(ApiError.BAD_REQUEST)
  error.description = description
  return error
}

function describeUploadRequest(input: UploadFileOperationInput, context: UploadFileOperationContext) {
  return {
    type: input.type,
    userId: context.currentUserId,
    sessionId: context.currentSessionId,
    ip: context.ip,
    filePresent: input.file != null,
    fileName: input.file?.name,
    fileSize: input.file?.size,
    fileMimeType: input.file?.type,
    thumbnailPresent: input.thumbnail != null,
    thumbnailName: input.thumbnail?.name,
    thumbnailSize: input.thumbnail?.size,
    thumbnailMimeType: input.thumbnail?.type,
    width: input.width,
    height: input.height,
    duration: input.duration,
  }
}
