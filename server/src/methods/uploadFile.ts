import { TMakeApiResponse, type HandlerContext } from "@in/server/controllers/helpers"
import { Optional, Type } from "@sinclair/typebox"
import Elysia, { t } from "elysia"
import type { Static } from "elysia"
import { MAX_FILE_SIZE } from "@in/server/config"
import { authenticate } from "@in/server/controllers/plugins"
import { FileTypes } from "@in/server/modules/files/types"
import { uploadPhoto } from "@in/server/modules/files/uploadPhoto"

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
})

export const Response = Type.Object({
  fileUniqueId: Type.String(),
})

const handler = async (input: Static<typeof Input>, context: HandlerContext): Promise<Static<typeof Response>> => {
  let fileUniqueId: string

  switch (input.type) {
    case FileTypes.PHOTO:
      fileUniqueId = (await uploadPhoto(input.file, { userId: context.currentUserId }))?.fileUniqueId
      break
    case FileTypes.VIDEO:
      throw new Error("Not implemented")
    case FileTypes.DOCUMENT:
      throw new Error("Not implemented")
  }

  return { fileUniqueId }
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
