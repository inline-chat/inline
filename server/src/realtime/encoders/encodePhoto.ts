import type { DbFile } from "@in/server/db/schema"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { getSignedUrl } from "@in/server/modules/files/path"
import { Photo_Format, PhotoSize, type Photo } from "@in/protocol/core"
import type { DbFullPhoto, DbFullPhotoSize } from "@in/server/db/models/files"

const encodePhotoSize = (size: DbFullPhotoSize): PhotoSize | null => {
  let file = size.file

  if (!file) return null

  const path = file.path
  const url = path ? getSignedUrl(path) : null

  let proto: PhotoSize = {
    type: size.size ?? "f",
    w: file.width ?? 0,
    h: file.height ?? 0,
    size: file.fileSize ?? 0,
    bytes: undefined,
    cdnUrl: url ?? undefined,
  }

  return proto
}

export const encodePhoto = ({ photo }: { photo: DbFullPhoto }) => {
  let proto: Photo = {
    id: BigInt(photo.id),
    date: BigInt(photo.date.getTime() / 1000),
    format: photo.format === "png" ? Photo_Format.PNG : Photo_Format.JPEG,
    sizes: photo.photoSizes?.map(encodePhotoSize).filter((size) => size !== null) ?? [],
  }

  return proto
}

export const encodePhotoLegacy = ({ file }: { file: DbFile }) => {
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
