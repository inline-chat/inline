import { Elysia, t } from "elysia"
import { getR2 } from "@in/server/libs/r2"
import { FILES_PATH_PREFIX, PHOTO_MEDIA_ROUTE_PATH, verifySignedMediaPhotoUrl } from "@in/server/modules/files/path"
import { getFileByUniqueId } from "@in/server/db/models/files"
import { decrypt } from "@in/server/modules/encryption/encryption"

export const media = new Elysia({ name: "media", prefix: "" }).get(
  PHOTO_MEDIA_ROUTE_PATH,
  async ({ query, set }) => {
    const exp = Number.parseInt(query.exp, 10)
    const fileUniqueId = query.id
    const sig = query.sig

    if (!verifySignedMediaPhotoUrl({ fileUniqueId, exp, sig })) {
      set.status = 403
      return "forbidden"
    }

    const fileRecord = await getFileByUniqueId(fileUniqueId)
    if (!fileRecord || fileRecord.fileType !== "photo") {
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

    return new Response(bucketFile.stream(), {
      headers: {
        "content-type": fileRecord.mimeType ?? "image/jpeg",
        "cache-control": `public, max-age=${maxAge}`,
        "x-content-type-options": "nosniff",
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
