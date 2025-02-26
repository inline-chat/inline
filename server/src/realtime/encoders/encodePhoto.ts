import type { DbFile } from "@in/server/db/schema"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { getSignedUrl } from "@in/server/modules/files/path"
import { Photo_Format, type Photo } from "@in/protocol/core"

export const encodePhoto = ({ file }: { file: DbFile }) => {
  const path =
    file.pathEncrypted && file.pathIv && file.pathTag
      ? decrypt({ encrypted: file.pathEncrypted, iv: file.pathIv, authTag: file.pathTag })
      : null

  const url = path ? getSignedUrl(path) : null

  let proto: Photo = {
    id: BigInt(file.id),
    date: BigInt(file.date.getTime() / 1000),
    fileUniqueId: file.fileUniqueId,
    format: file.mimeType === "image/png" ? Photo_Format.PNG : Photo_Format.JPEG,
    sizes: [
      {
        type: "f",
        w: file.width ?? 0,
        h: file.height ?? 0,
        size: file.fileSize ?? 0,
        bytes: undefined,
        cdnUrl: url ?? undefined,
      },
    ],
  }

  return proto
}
