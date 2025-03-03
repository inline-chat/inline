import { nanoid } from "nanoid/non-secure"
import { type FileTypes, type UploadFileResult } from "@in/server/modules/files/types"
import { generateFileUniqueId } from "@in/server/modules/files/fileId"
import { uploadToBucket } from "@in/server/modules/files/uploadToBucket"
import { files, type DbNewFile } from "@in/server/db/schema"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { db } from "@in/server/db"
import { FILES_PATH_PREFIX } from "@in/server/modules/files/path"

export interface FileMetadata {
  width?: number
  height?: number
  extension: string
  mimeType: string
  fileName: string
}

export async function uploadFile(
  file: File,
  fileType: FileTypes,
  metadata: FileMetadata,
  context: { userId: number },
): Promise<{ dbFile: DbNewFile; fileUniqueId: string; prefix: string }> {
  const fileUniqueId = generateFileUniqueId(fileType)
  const prefix = nanoid(32)
  const path = `${fileUniqueId}/${prefix}.${metadata.extension}`
  const bucketPath = `${FILES_PATH_PREFIX}/${path}`

  // Upload file to bucket
  await uploadToBucket(file, { path: bucketPath, type: metadata.mimeType })

  let encryptedPath = encrypt(path)
  let encryptedName = encrypt(metadata.fileName)

  const dbNewFile: DbNewFile = {
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

    fileType,
    fileSize: file.size,
    width: metadata.width,
    height: metadata.height,
    mimeType: metadata.mimeType,
  }

  // Save to DB
  let [dbFile] = await db.insert(files).values(dbNewFile).returning()

  if (!dbFile) {
    throw new Error("Failed to save file to DB")
  }

  return { dbFile, fileUniqueId, prefix }
}
