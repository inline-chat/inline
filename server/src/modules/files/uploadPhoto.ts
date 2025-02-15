import { getPhotoMetadataAndValidate } from "@in/server/modules/files/metadata"
import { nanoid } from "nanoid/non-secure"
import { FileTypes } from "@in/server/modules/files/types"
import { generateFileUniqueId } from "@in/server/modules/files/fileId"
import { uploadToBucket } from "@in/server/modules/files/uploadToBucket"
import { files, type DbNewFile } from "@in/server/db/schema"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { db } from "@in/server/db"
import { FILES_PATH_PREFIX } from "@in/server/modules/files/path"

export async function uploadPhoto(file: File, context: { userId: number }): Promise<{ fileUniqueId: string }> {
  // Get metadata and validate
  const { width, height, extension, mimeType, fileName } = await getPhotoMetadataAndValidate(file)

  const fileUniqueId = generateFileUniqueId(FileTypes.PHOTO)
  const prefix = nanoid(32)
  const path = `${fileUniqueId}/${prefix}.${extension}`
  const bucketPath = `${FILES_PATH_PREFIX}/${path}`

  const filesArray: DbNewFile[] = []

  // Upload OG photo
  await uploadToBucket(file, { path: bucketPath, type: mimeType })

  // Generate thumbhash and store that
  // Upload thumbnails...
  // TODO: Implement this

  let encryptedPath = encrypt(path)
  let encryptedName = encrypt(fileName)

  filesArray.push({
    fileUniqueId,
    userId: context.userId,

    // Path
    pathEncrypted: encryptedPath.encrypted,
    pathIv: encryptedPath.iv,
    pathTag: encryptedPath.authTag,

    // original file name
    nameEncrypted: encryptedName.encrypted,
    nameIv: encryptedName.iv,
    nameTag: encryptedName.authTag,

    fileType: FileTypes.PHOTO,
    fileSize: file.size,
    width,
    height,
    mimeType,
  })

  // Save to DB
  let _ = await db.insert(files).values(filesArray).returning()

  return { fileUniqueId }
}

function generateThumbnails(file: File, fileUniqueId: string, prefix: string) {
  // TODO: Implement this
}

function generateThumbhash(file: File, fileUniqueId: string, prefix: string) {
  // TODO: Implement this
}
