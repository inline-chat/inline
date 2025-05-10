import { nanoid } from "nanoid/non-secure"
import { type FileTypes, type UploadFileResult } from "@in/server/modules/files/types"
import { generateFileUniqueId } from "@in/server/modules/files/fileId"
import { uploadToBucket } from "@in/server/modules/files/uploadToBucket"
import { files, type DbNewFile } from "@in/server/db/schema"
import { encrypt, type EncryptedData } from "@in/server/modules/encryption/encryption"
import { db } from "@in/server/db"
import { FILES_PATH_PREFIX } from "@in/server/modules/files/path"
import { Log } from "@in/server/utils/log"

const log = new Log("modules/files/uploadAFile")

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
  try {
    log.info("Starting file upload", { fileType, fileSize: file.size, userId: context.userId })

    const fileUniqueId = generateFileUniqueId(fileType)
    const prefix = nanoid(32)
    const path = `${fileUniqueId}/${prefix}.${metadata.extension}`
    const bucketPath = `${FILES_PATH_PREFIX}/${path}`

    // Upload file to bucket
    try {
      await uploadToBucket(file, { path: bucketPath, type: metadata.mimeType })
      log.info("File uploaded to bucket successfully", { bucketPath })
    } catch (error) {
      log.error("Failed to upload file to bucket", { error, bucketPath })
      throw new Error("Failed to upload file to storage")
    }

    let encryptedPath: EncryptedData
    let encryptedName: EncryptedData

    try {
      encryptedPath = encrypt(path)
      encryptedName = encrypt(metadata.fileName)
      log.info("File metadata encrypted successfully")
    } catch (error) {
      log.error("Failed to encrypt file metadata", { error })
      throw new Error("Failed to encrypt file metadata")
    }

    const dbNewFile: DbNewFile = {
      fileUniqueId,
      userId: context.userId,
      pathEncrypted: encryptedPath.encrypted,
      pathIv: encryptedPath.iv,
      pathTag: encryptedPath.authTag,
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
    try {
      let [dbFile] = await db.insert(files).values(dbNewFile).returning()
      if (!dbFile) {
        throw new Error("No file returned from database")
      }
      log.info("File saved to database successfully", { fileUniqueId })
      return { dbFile, fileUniqueId, prefix }
    } catch (error) {
      log.error("Failed to save file to database", { error, fileUniqueId })
      throw new Error("Failed to save file to database")
    }
  } catch (error) {
    log.error("File upload failed", { error, fileType, userId: context.userId })
    throw error
  }
}
