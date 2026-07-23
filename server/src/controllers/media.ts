import { Elysia, t } from "elysia"
import { getR2 } from "@in/server/libs/r2"
import { FILES_PATH_PREFIX, MEDIA_FILE_ROUTE_PATH, verifySignedMediaFileUrl } from "@in/server/modules/files/path"
import { getFileByUniqueId } from "@in/server/db/models/files"
import { decrypt } from "@in/server/modules/encryption/encryption"
import {
  createMediaFileResponse,
  isSupportedMediaFileType,
} from "@in/server/modules/files/mediaResponse"

export const media = new Elysia({ name: "media", prefix: "" }).get(
  MEDIA_FILE_ROUTE_PATH,
  async ({ query, request, set }) => {
    const exp = Number.parseInt(query.exp, 10)
    const fileUniqueId = query.id
    const sig = query.sig

    if (!verifySignedMediaFileUrl({ fileUniqueId, exp, sig })) {
      set.status = 403
      return "forbidden"
    }

    const fileRecord = await getFileByUniqueId(fileUniqueId)
    if (
      !fileRecord ||
      !isSupportedMediaFileType(fileRecord.fileType)
    ) {
      set.status = 404
      return "not_found"
    }

    let path: string | null = null
    try {
      path =
        fileRecord.pathEncrypted && fileRecord.pathIv && fileRecord.pathTag
          ? decrypt({ encrypted: fileRecord.pathEncrypted, iv: fileRecord.pathIv, authTag: fileRecord.pathTag })
          : null
    } catch {
      path = null
    }
    if (!path) {
      set.status = 404
      return "not_found"
    }

    const r2 = getR2()
    if (!r2) {
      set.status = 503
      return "storage_unavailable"
    }

    const objectPath = `${FILES_PATH_PREFIX}/${path}`
    const bucketFile = r2.file(objectPath)
    if (!(await bucketFile.exists())) {
      set.status = 404
      return "not_found"
    }

    const now = Math.floor(Date.now() / 1000)
    const maxAge = Math.max(0, Math.min(exp - now, 3600))
    return createMediaFileResponse({
      object: bucketFile,
      fileUniqueId,
      fileSize: fileRecord.fileSize,
      mimeType: fileRecord.mimeType,
      maxAge,
      forceDownload:
        fileRecord.fileType === "document",
      requestHeaders: {
        range: request.headers.get("range") ?? undefined,
        ifRange:
          request.headers.get("if-range") ?? undefined,
        ifNoneMatch:
          request.headers.get("if-none-match") ?? undefined,
      },
    })
  },
  {
    query: t.Object({
      id: t.String(),
      exp: t.String(),
      sig: t.String(),
    }),
  },
)
