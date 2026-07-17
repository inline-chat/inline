import { TMakeApiResponse } from "@in/server/controllers/helpers"
import { Optional, Type } from "@sinclair/typebox"
import Elysia, { t } from "elysia"
import { MAX_FILE_SIZE } from "@in/server/config"
import { authenticate } from "@in/server/controllers/plugins"
import { FileTypes } from "@in/server/modules/files/types"
import { Log } from "@in/server/utils/log"
import { getIp } from "@in/server/utils/ip"
import { uploadFileOperation } from "./uploadFileOperation"

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
  isAnimated: Optional(Type.String()),
  hasAudio: Optional(Type.String()),
  waveform: Optional(Type.String()),

  // For documents
  // photoId: Optional(Type.Number()),
})

export const Response = Type.Object({
  fileUniqueId: Type.String(),
  photoId: Type.Optional(Type.Number()),
  videoId: Type.Optional(Type.Number()),
  documentId: Type.Optional(Type.Number()),
  voiceId: Type.Optional(Type.Number()),
})

// Route
const response = TMakeApiResponse(Response)
export const uploadFileRoute = new Elysia({ tags: ["POST"] }).use(authenticate).post(
  "/uploadFile",
  async ({ body: input, store, server, request }) => {
    const ip = getIp(request, server)

    try {
      const context = {
        currentUserId: store.currentUserId,
        currentSessionId: store.currentSessionId,
        ip,
      }

      let result = await uploadFileOperation(input, context)
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
