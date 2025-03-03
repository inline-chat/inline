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

export const Input = Type.Object({
  type: Type.Enum(FileTypes),
  file: t.File({
    maxItems: 1,
    maxSize: MAX_FILE_SIZE,
    description: "File, photo or video to upload",
  }),
  thumbnail: Optional(
    t.File({
      maxItems: 1,
      maxSize: MAX_FILE_SIZE,
      description: "Thumbnail image for video or uncompressed photo (optional)",
    }),
  ),

  // For videos
  width: Optional(Type.Number()),
  height: Optional(Type.Number()),
  duration: Optional(Type.Number()),

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
  let result: UploadFileResult

  switch (input.type) {
    case FileTypes.PHOTO:
      result = await uploadPhoto(input.file, { userId: context.currentUserId })
      break
    case FileTypes.VIDEO:
      result = await uploadVideo(
        input.file,
        {
          width: input.width ?? 1280,
          height: input.height ?? 720,
          duration: input.duration ?? 0,
        },
        { userId: context.currentUserId },
      )
      break
    case FileTypes.DOCUMENT:
      result = await uploadDocument(input.file, undefined, { userId: context.currentUserId })
      break
  }

  return {
    fileUniqueId: result.fileUniqueId,
    photoId: result.photoId,
    videoId: result.videoId,
    documentId: result.documentId,
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
    const context = {
      currentUserId: store.currentUserId,
      currentSessionId: store.currentSessionId,
      ip,
    }
    let result = await handler(input, context)
    return { ok: true, result } as any
  },
  {
    type: "multipart/form-data",
    body: Input,
    response: response,
  },
)
