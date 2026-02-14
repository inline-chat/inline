import { TMakeApiResponse, type HandlerContext } from "@in/server/controllers/helpers"
import { Optional, Type } from "@sinclair/typebox"
import Elysia, { t } from "elysia"
import type { Static } from "elysia"
import { MAX_FILE_SIZE } from "@in/server/config"
import { authenticate } from "@in/server/controllers/plugins"
import { FileTypes, type UploadFileResult } from "@in/server/modules/files/types"
import { uploadPhoto } from "@in/server/modules/files/uploadPhoto"
import { uploadDocument } from "@in/server/modules/files/uploadDocument"
import { uploadVideo } from "@in/server/modules/files/uploadVideo"
import { ApiError, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"

const log = new Log("methods/uploadFile")

export const Input = Type.Object({
  type: Type.Enum(FileTypes),
  file: Optional(
    t.File({
      maxItems: 1,
      maxSize: MAX_FILE_SIZE,
      description: "File, photo or video to upload",
    }),
  ),
  thumbnail: Optional(
    t.File({
      maxItems: 1,
      maxSize: MAX_FILE_SIZE,
      description: "Thumbnail image for video or uncompressed photo (optional)",
    }),
  ),

  // For videos
  width: Optional(Type.String()),
  height: Optional(Type.String()),
  duration: Optional(Type.String()),

  // For documents
  // photoId: Optional(Type.Number()),
})

export const Response = Type.Object({
  fileUniqueId: Type.String(),
  photoId: Type.Optional(Type.Number()),
  videoId: Type.Optional(Type.Number()),
  documentId: Type.Optional(Type.Number()),
})

const handler = async (input: Static<typeof Input>, context: HandlerContext): Promise<Static<typeof Response>> => {
  const requestDiagnostics = describeUploadRequest(input, context)
  try {
    log.info("Starting file upload request", requestDiagnostics)

    const file = requireUploadFile(input.file)

    const width = input.type === FileTypes.VIDEO ? parseOptionalInt("width", input.width, 1) : undefined
    const height = input.type === FileTypes.VIDEO ? parseOptionalInt("height", input.height, 1) : undefined
    const duration =
      input.type === FileTypes.VIDEO ? parseOptionalInt("duration", input.duration, 0) : undefined

    if (input.thumbnail?.size === 0) {
      throw uploadBadRequest("Uploaded thumbnail is empty")
    }
    if (input.thumbnail && input.thumbnail.size > MAX_FILE_SIZE) {
      throw new InlineError(ApiError.FILE_TOO_LARGE)
    }
    if (input.thumbnail != null && !input.thumbnail.type?.trim()) {
      throw uploadBadRequest("Uploaded thumbnail is missing MIME type")
    }

    // Validate required video metadata
    if (input.type === FileTypes.VIDEO) {
      if (width === undefined || height === undefined || duration === undefined) {
        log.error("Missing video metadata", {
          ...requestDiagnostics,
          hasWidth: width !== undefined,
          hasHeight: height !== undefined,
          hasDuration: duration !== undefined,
        })
        throw uploadBadRequest("Video upload requires width, height, and duration")
      }
    }

    let result: UploadFileResult
    let videoThumbnailId: number | undefined

    try {
      switch (input.type) {
        case FileTypes.PHOTO:
          result = await uploadPhoto(file, { userId: context.currentUserId })
          break
        case FileTypes.VIDEO:
          // Upload optional thumbnail first so we can associate it with the video row
          if (input.thumbnail) {
            const thumbResult = await uploadPhoto(input.thumbnail, { userId: context.currentUserId })
            videoThumbnailId = thumbResult.photoId
          }

          result = await uploadVideo(
            file,
            {
              width: width ?? 1280,
              height: height ?? 720,
              duration: duration ?? 0,
              photoId: videoThumbnailId ? BigInt(videoThumbnailId) : undefined,
            },
            { userId: context.currentUserId },
          )
          break
        case FileTypes.DOCUMENT:
          result = await uploadDocument(file, undefined, { userId: context.currentUserId })
          break
      }
    } catch (error) {
      log.error("File upload failed", { error, ...requestDiagnostics })
      throw error
    }

    log.info("File upload completed successfully", {
      ...requestDiagnostics,
      fileUniqueId: result.fileUniqueId,
    })

    return {
      fileUniqueId: result.fileUniqueId,
      photoId: result.photoId ?? videoThumbnailId,
      videoId: result.videoId,
      documentId: result.documentId,
    }
  } catch (error) {
    log.error("File upload request failed", { error, ...requestDiagnostics })
    throw error
  }
}

// Route
const response = TMakeApiResponse(Response)
export const uploadFileRoute = new Elysia({ tags: ["POST"] }).use(authenticate).post(
  "/uploadFile",
  async ({ body: input, store, server, request }) => {
    const ip =
      request.headers.get("x-forwarded-for") ??
      request.headers.get("cf-connecting-ip") ??
      request.headers.get("x-real-ip") ??
      server?.requestIP(request)?.address

    try {
      const context = {
        currentUserId: store.currentUserId,
        currentSessionId: store.currentSessionId,
        ip,
      }

      let result = await handler(input, context)
      return { ok: true, result } as any
    } catch (error) {
      log.error("Upload file route error", {
        error,
        userId: store.currentUserId,
        sessionId: store.currentSessionId,
        ip,
        type: input?.type,
        fileName: input?.file?.name,
        fileSize: input?.file?.size,
        fileMimeType: input?.file?.type,
      })
      throw error
    }
  },
  {
    type: "multipart/form-data",
    body: Input,
    response: response,
  },
)

function parseOptionalInt(name: string, value: string | undefined, min: number): number | undefined {
  if (value === undefined) return undefined
  const trimmed = value.trim()
  if (!trimmed) {
    log.error("Invalid numeric upload metadata", { name, value, reason: "empty" })
    throw uploadBadRequest(`Invalid ${name}: expected a number`)
  }

  const parsed = Number(trimmed)
  if (!Number.isInteger(parsed) || parsed < min) {
    log.error("Invalid numeric upload metadata", { name, value, min, parsed })
    throw uploadBadRequest(`Invalid ${name}: expected integer >= ${min}`)
  }

  return parsed
}

function requireUploadFile(file: File | undefined): File {
  if (!file) {
    throw uploadBadRequest("Missing multipart file field `file`")
  }
  if (file.size === 0) {
    throw uploadBadRequest("Uploaded file is empty")
  }
  if (file.size > MAX_FILE_SIZE) {
    throw new InlineError(ApiError.FILE_TOO_LARGE)
  }
  if (!file.type?.trim()) {
    throw uploadBadRequest("Uploaded file is missing MIME type")
  }
  return file
}

function uploadBadRequest(description: string): InlineError {
  const error = new InlineError(ApiError.BAD_REQUEST)
  error.description = description
  return error
}

function describeUploadRequest(input: Static<typeof Input>, context: HandlerContext) {
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
