import type { DbFile } from "@in/server/db/schema"
import { decryptBinary } from "@in/server/modules/encryption/encryption"
import { getSignedMediaPhotoUrl } from "@in/server/modules/files/path"
import { getStrippedThumbnailDimensions } from "@in/server/modules/files/strippedThumbnail"
import { Photo_Format, PhotoSize, type Photo } from "@inline-chat/protocol/core"
import type { DbFullPhoto, DbFullPhotoSize } from "@in/server/db/models/files"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

const encodePhotoSize = (size: DbFullPhotoSize): PhotoSize | null => {
  let file = size.file

  if (!file) return null

  const url = getSignedMediaPhotoUrl(file)

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

const encodeStrippedPhotoSize = (photo: DbFullPhoto): PhotoSize | null => {
  if (!photo.stripped || !photo.strippedIv || !photo.strippedTag) {
    return null
  }

  try {
    const bytes = decryptBinary({
      encrypted: photo.stripped,
      iv: photo.strippedIv,
      authTag: photo.strippedTag,
    })
    const { width, height } = getStrippedThumbnailDimensions(bytes)

    return {
      type: "s",
      w: width,
      h: height,
      size: bytes.length,
      bytes,
      cdnUrl: undefined,
    }
  } catch {
    return null
  }
}

export const encodePhoto = ({ photo }: { photo: DbFullPhoto }) => {
  const strippedSize = encodeStrippedPhotoSize(photo)
  const fileSizes = photo.photoSizes?.map(encodePhotoSize).filter((size) => size !== null) ?? []

  let proto: Photo = {
    id: BigInt(photo.id),
    date: encodeDateStrict(photo.date),
    format: photo.format === "png" ? Photo_Format.PNG : Photo_Format.JPEG,
    sizes: strippedSize ? [strippedSize, ...fileSizes] : fileSizes,
  }

  return proto
}

export const encodePhotoLegacy = ({ file }: { file: DbFile }) => {
  const url = getSignedMediaPhotoUrl(file)

  let proto: Photo = {
    id: BigInt(file.id),
    date: encodeDateStrict(file.date),
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
