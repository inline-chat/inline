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

  const thumbnail = input.type === "document"
    ? usableOptionalDocumentThumbnail(input.thumbnail, context.currentUserId)
    : requireValidThumbnail(input.thumbnail)

  let result: UploadFileResult
  let uploadedThumbnailId: number | undefined

  switch (input.type) {
    case "photo":
      result = await uploadPhoto(file, { userId: context.currentUserId })
      break
    case "video":
      if (thumbnail) {
        const thumbResult = await uploadPhoto(thumbnail, { userId: context.currentUserId })
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
      result = await uploadDocumentWithOptionalThumbnail(
        file,
        thumbnail,
        context.currentUserId,
      )
      uploadedThumbnailId = result.photoId
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

export const uploadOptionalDocumentThumbnail = async (
  thumbnail: File,
  userId: number,
  upload: typeof uploadPhoto = uploadPhoto,
): Promise<number | undefined> => {
  try {
    return (await upload(thumbnail, { userId })).photoId
  } catch (error) {
    log.warn("Optional document thumbnail upload failed; continuing without preview", {
      userId,
      thumbnailSize: thumbnail.size,
      thumbnailMimeType: thumbnail.type,
      error,
    })
    return undefined
  }
}

export const uploadDocumentWithOptionalThumbnail = async (
  file: File,
  thumbnail: File | undefined,
  userId: number,
  uploadThumbnail: typeof uploadPhoto = uploadPhoto,
  upload: typeof uploadDocument = uploadDocument,
): Promise<UploadFileResult> => {
  const thumbnailId = thumbnail
    ? await uploadOptionalDocumentThumbnail(thumbnail, userId, uploadThumbnail)
    : undefined
  const result = await upload(
    file,
    thumbnailId ? BigInt(thumbnailId) : undefined,
    { userId },
  )
  return { ...result, photoId: result.photoId ?? thumbnailId }
}

export const usableOptionalDocumentThumbnail = (
  thumbnail: File | null | undefined,
  userId: number,
): File | undefined => {
  if (!thumbnail) {
    return undefined
  }

  const invalidReason = thumbnailValidationFailure(thumbnail)
  if (invalidReason) {
    log.warn("Ignoring invalid optional document thumbnail", {
      userId,
      thumbnailSize: thumbnail.size,
      thumbnailMimeType: thumbnail.type,
      reason: invalidReason.message,
    })
    return undefined
  }

  return thumbnail
}

function requireValidThumbnail(thumbnail: File | null | undefined): File | undefined {
  if (!thumbnail) {
    return undefined
  }

  const failure = thumbnailValidationFailure(thumbnail)
  if (failure) {
    throw failure
  }
  return thumbnail
}

function thumbnailValidationFailure(thumbnail: File): InlineError | undefined {
  if (thumbnail.size === 0) {
    return uploadBadRequest("Uploaded thumbnail is empty")
  }
  if (thumbnail.size > MAX_FILE_SIZE) {
    return new InlineError(ApiError.FILE_TOO_LARGE)
  }
  if (!thumbnail.type?.trim()) {
    return uploadBadRequest("Uploaded thumbnail is missing MIME type")
  }
  return undefined
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
