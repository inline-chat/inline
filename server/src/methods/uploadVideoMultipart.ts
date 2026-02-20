import { TMakeApiResponse, type HandlerContext } from "@in/server/controllers/helpers"
import { authenticate } from "@in/server/controllers/plugins"
import { db } from "@in/server/db"
import { videos } from "@in/server/db/schema"
import { FILES_PATH_PREFIX } from "@in/server/config"
import Elysia, { t } from "elysia"
import { Type } from "@sinclair/typebox"
import { nanoid } from "nanoid"
import { FileTypes } from "@in/server/modules/files/types"
import { generateFileUniqueId } from "@in/server/modules/files/fileId"
import {
  abortR2MultipartUpload,
  completeR2MultipartUpload,
  createMultipartUploadForR2,
  deleteObjectFromR2,
  getR2ObjectSize,
  uploadPartToR2Multipart,
} from "@in/server/libs/r2Multipart"
import {
  createVideoMultipartSessionToken,
  verifyVideoMultipartSessionToken,
} from "@in/server/modules/files/multipartUploadSession"
import { maxVideoFileSize, validateVideoMetadataInput } from "@in/server/modules/files/metadata"
import { ApiError, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { uploadPhoto } from "@in/server/modules/files/uploadPhoto"
import { persistUploadedFileRecord } from "@in/server/modules/files/uploadAFile"

const log = new Log("methods/uploadVideoMultipart")

const MULTIPART_PART_SIZE_BYTES = 16 * 1024 * 1024
const MULTIPART_MIN_PART_SIZE_BYTES = 5 * 1024 * 1024
const MULTIPART_MAX_PARTS = 10_000

const InitInput = Type.Object({
  fileName: Type.String({ minLength: 1, maxLength: 512 }),
  mimeType: Type.String({ minLength: 1, maxLength: 256 }),
  fileSize: Type.Integer({ minimum: 1, maximum: maxVideoFileSize }),
  width: Type.Integer({ minimum: 1 }),
  height: Type.Integer({ minimum: 1 }),
  duration: Type.Integer({ minimum: 0 }),
})

const InitResponse = Type.Object({
  sessionToken: Type.String(),
  partSize: Type.Number(),
  totalParts: Type.Number(),
})

const PartInput = Type.Object({
  sessionToken: Type.String(),
  partNumber: Type.String(),
  chunk: t.File({
    maxItems: 1,
    maxSize: MULTIPART_PART_SIZE_BYTES,
    description: "Binary part chunk for multipart video upload",
  }),
})

const PartResponse = Type.Object({
  partNumber: Type.Number(),
  eTag: Type.String(),
})

const CompleteInput = Type.Object({
  sessionToken: Type.String(),
  parts: Type.String(),
  thumbnail: Type.Optional(
    t.File({
      maxItems: 1,
      maxSize: 40_000_000,
      description: "Optional thumbnail image for video",
    }),
  ),
})

const CompleteResponse = Type.Object({
  fileUniqueId: Type.String(),
  photoId: Type.Optional(Type.Number()),
  videoId: Type.Optional(Type.Number()),
  documentId: Type.Optional(Type.Number()),
})

const AbortInput = Type.Object({
  sessionToken: Type.String(),
})

const AbortResponse = Type.Object({
  aborted: Type.Boolean(),
})

type MultipartPart = {
  partNumber: number
  eTag: string
}

const initResponse = TMakeApiResponse(InitResponse)
const partResponse = TMakeApiResponse(PartResponse)
const completeResponse = TMakeApiResponse(CompleteResponse)
const abortResponse = TMakeApiResponse(AbortResponse)

const getContext = (store: { currentUserId: number; currentSessionId: number }, ip: string | undefined): HandlerContext => {
  return {
    currentUserId: store.currentUserId,
    currentSessionId: store.currentSessionId,
    ip,
  }
}

const getRequestIp = (
  request: Request,
  server: { requestIP(request: Request): { address: string } | null } | null,
): string | undefined => {
  return (
    request.headers.get("x-forwarded-for") ??
    request.headers.get("cf-connecting-ip") ??
    request.headers.get("x-real-ip") ??
    server?.requestIP(request)?.address ??
    undefined
  )
}

const verifySessionOrThrow = (sessionToken: string, currentUserId: number) => {
  const session = verifyVideoMultipartSessionToken(sessionToken)
  if (!session) {
    throw uploadBadRequest("Upload session is invalid or expired")
  }

  if (session.userId !== currentUserId) {
    throw new InlineError(ApiError.UNAUTHORIZED)
  }

  return session
}

const parsePartNumber = (value: string): number => {
  const parsed = Number(value.trim())
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw uploadBadRequest("Invalid partNumber")
  }
  return parsed
}

const parsePartsOrThrow = (rawParts: string): MultipartPart[] => {
  let parsed: unknown
  try {
    parsed = JSON.parse(rawParts)
  } catch {
    throw uploadBadRequest("Invalid parts payload")
  }

  if (!Array.isArray(parsed) || parsed.length === 0) {
    throw uploadBadRequest("Parts list is required")
  }

  const parts: MultipartPart[] = []
  for (const item of parsed) {
    if (typeof item !== "object" || item == null) {
      throw uploadBadRequest("Invalid part entry")
    }

    const partNumber = Number((item as { partNumber?: unknown }).partNumber)
    const eTag = (item as { eTag?: unknown }).eTag

    if (!Number.isInteger(partNumber) || partNumber <= 0 || typeof eTag !== "string" || eTag.length === 0) {
      throw uploadBadRequest("Invalid part entry")
    }

    parts.push({ partNumber, eTag })
  }

  return parts
}

export const uploadVideoMultipartRoute = new Elysia({ tags: ["POST"] })
  .use(authenticate)
  .post(
    "/uploadVideoMultipartInit",
    async ({ body, store, request, server }) => {
      const ip = getRequestIp(request, server)
      const context = getContext(store, ip)

      const metadata = validateVideoMetadataInput({
        width: body.width,
        height: body.height,
        duration: body.duration,
        fileName: body.fileName,
        size: body.fileSize,
        mimeType: body.mimeType,
      })

      const totalParts = Math.ceil(body.fileSize / MULTIPART_PART_SIZE_BYTES)
      if (totalParts <= 0 || totalParts > MULTIPART_MAX_PARTS) {
        throw uploadBadRequest("Video exceeds multipart upload part limit")
      }

      const fileUniqueId = generateFileUniqueId(FileTypes.VIDEO)
      const prefix = nanoid(32)
      const path = `${fileUniqueId}/${prefix}.${metadata.extension}`
      const bucketPath = `${FILES_PATH_PREFIX}/${path}`

      const uploadId = await createMultipartUploadForR2(bucketPath, metadata.mimeType)

      const sessionToken = createVideoMultipartSessionToken({
        userId: context.currentUserId,
        uploadId,
        fileUniqueId,
        path,
        bucketPath,
        fileName: metadata.fileName,
        mimeType: metadata.mimeType,
        extension: metadata.extension,
        fileSize: body.fileSize,
        width: metadata.width,
        height: metadata.height,
        duration: metadata.duration,
        partSize: MULTIPART_PART_SIZE_BYTES,
        totalParts,
      })

      log.info("Initialized video multipart upload", {
        userId: context.currentUserId,
        fileUniqueId,
        fileSize: body.fileSize,
        totalParts,
      })

      return {
        ok: true,
        result: {
          sessionToken,
          partSize: MULTIPART_PART_SIZE_BYTES,
          totalParts,
        },
      } as const
    },
    {
      body: InitInput,
      response: initResponse,
      type: "application/json",
    },
  )
  .post(
    "/uploadVideoMultipartPart",
    async ({ body, store, request, server }) => {
      const ip = getRequestIp(request, server)
      const context = getContext(store, ip)
      const session = verifySessionOrThrow(body.sessionToken, context.currentUserId)
      const partNumber = parsePartNumber(body.partNumber)

      if (partNumber > session.totalParts) {
        throw uploadBadRequest("Part number exceeds total parts")
      }

      if (body.chunk.size <= 0) {
        throw uploadBadRequest("Chunk is empty")
      }

      const isLastPart = partNumber == session.totalParts
      if (!isLastPart && body.chunk.size != session.partSize) {
        throw uploadBadRequest("Non-final chunk size must match part size")
      }

      if (!isLastPart && body.chunk.size < MULTIPART_MIN_PART_SIZE_BYTES) {
        throw uploadBadRequest("Non-final chunk size is below multipart minimum")
      }

      if (body.chunk.size > session.partSize) {
        throw uploadBadRequest("Chunk exceeds part size")
      }

      const bytes = new Uint8Array(await body.chunk.arrayBuffer())
      const eTag = await uploadPartToR2Multipart({
        key: session.bucketPath,
        uploadId: session.uploadId,
        partNumber,
        body: bytes,
      })

      return {
        ok: true,
        result: {
          partNumber,
          eTag,
        },
      } as const
    },
    {
      type: "multipart/form-data",
      body: PartInput,
      response: partResponse,
    },
  )
  .post(
    "/uploadVideoMultipartComplete",
    async ({ body, store, request, server }) => {
      const ip = getRequestIp(request, server)
      const context = getContext(store, ip)
      const session = verifySessionOrThrow(body.sessionToken, context.currentUserId)
      const parsedParts = parsePartsOrThrow(body.parts)

      const dedupedPartNumbers = new Set<number>()
      for (const part of parsedParts) {
        if (part.partNumber > session.totalParts) {
          throw uploadBadRequest("Part number exceeds total parts")
        }
        if (dedupedPartNumbers.has(part.partNumber)) {
          throw uploadBadRequest("Duplicate part number provided")
        }
        dedupedPartNumbers.add(part.partNumber)
      }

      if (dedupedPartNumbers.size !== session.totalParts) {
        throw uploadBadRequest("Missing part numbers in completion payload")
      }

      const sortedParts = parsedParts.sort((a, b) => a.partNumber - b.partNumber)
      for (let index = 0; index < sortedParts.length; index++) {
        if (sortedParts[index]?.partNumber !== index + 1) {
          throw uploadBadRequest("Parts must include all part numbers in sequence")
        }
      }

      await completeR2MultipartUpload({
        key: session.bucketPath,
        uploadId: session.uploadId,
        parts: sortedParts,
      })

      const objectSize = await getR2ObjectSize(session.bucketPath)
      if (objectSize == null || objectSize !== session.fileSize) {
        await deleteObjectFromR2(session.bucketPath)
        throw uploadBadRequest("Uploaded video size validation failed")
      }

      let photoId: number | undefined
      if (body.thumbnail) {
        if (body.thumbnail.size === 0) {
          throw uploadBadRequest("Uploaded thumbnail is empty")
        }
        if (!body.thumbnail.type?.trim()) {
          throw uploadBadRequest("Uploaded thumbnail is missing MIME type")
        }

        const thumbnailResult = await uploadPhoto(body.thumbnail, { userId: context.currentUserId })
        photoId = thumbnailResult.photoId
      }

      try {
        const dbFile = await persistUploadedFileRecord({
          fileUniqueId: session.fileUniqueId,
          fileSize: session.fileSize,
          path: session.path,
          fileType: FileTypes.VIDEO,
          metadata: {
            fileName: session.fileName,
            mimeType: session.mimeType,
            extension: session.extension,
            width: session.width,
            height: session.height,
          },
          context: {
            userId: context.currentUserId,
          },
        })

        const [video] = await db
          .insert(videos)
          .values({
            fileId: dbFile.id,
            width: session.width,
            height: session.height,
            duration: session.duration,
            photoId: photoId ? BigInt(photoId) : undefined,
            date: new Date(),
          })
          .returning()

        if (!video) {
          throw new Error("Failed to save video metadata")
        }

        return {
          ok: true,
          result: {
            fileUniqueId: session.fileUniqueId,
            photoId,
            videoId: video.id,
          },
        } as const
      } catch (error) {
        try {
          await deleteObjectFromR2(session.bucketPath)
        } catch (cleanupError) {
          log.error("Failed to cleanup multipart uploaded object after completion failure", {
            cleanupError,
            fileUniqueId: session.fileUniqueId,
            userId: context.currentUserId,
          })
        }

        throw error
      }
    },
    {
      type: "multipart/form-data",
      body: CompleteInput,
      response: completeResponse,
    },
  )
  .post(
    "/uploadVideoMultipartAbort",
    async ({ body, store, request, server }) => {
      const ip = getRequestIp(request, server)
      const context = getContext(store, ip)
      const session = verifySessionOrThrow(body.sessionToken, context.currentUserId)

      await abortR2MultipartUpload(session.bucketPath, session.uploadId)

      return {
        ok: true,
        result: {
          aborted: true,
        },
      } as const
    },
    {
      type: "application/json",
      body: AbortInput,
      response: abortResponse,
    },
  )

function uploadBadRequest(description: string): InlineError {
  const error = new InlineError(ApiError.BAD_REQUEST)
  error.description = description
  return error
}
