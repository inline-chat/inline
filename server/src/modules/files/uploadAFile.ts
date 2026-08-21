import { nanoid } from "nanoid"
import { type FileTypes } from "@in/server/modules/files/types"
import { generateFileUniqueId } from "@in/server/modules/files/fileId"
import { uploadToBucket } from "@in/server/modules/files/uploadToBucket"
import { files, type DbNewFile } from "@in/server/db/schema"
import { encrypt, type EncryptedData } from "@in/server/modules/encryption/encryption"
import { db } from "@in/server/db"
import { FILES_PATH_PREFIX } from "@in/server/modules/files/path"
import { ApiError, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"

const log = new Log("modules/files/uploadAFile")

export interface FileMetadata {
  width?: number
  height?: number
  extension: string
  mimeType: string
  fileName: string
}

export type FileObjectIdentity = {
  fileUniqueId: string
  path: string
}

export function createFileObjectIdentity(
  fileType: FileTypes,
  extension: string,
): FileObjectIdentity {
  const fileUniqueId = generateFileUniqueId(fileType)
  const normalizedExtension = extension.trim().toLowerCase()
  const suffix = normalizedExtension ? `.${normalizedExtension}` : ""
  return {
    fileUniqueId,
    path: `${fileUniqueId}/${nanoid(32)}${suffix}`,
  }
}

export type UploadedFileObject = {
  dbFile: {
    fileUniqueId: string
    userId: number
    pathEncrypted: Buffer
    pathIv: Buffer
    pathTag: Buffer
    nameEncrypted: Buffer
    nameIv: Buffer
    nameTag: Buffer
    fileType: FileTypes
    fileSize: number
    width?: number
    height?: number
    mimeType: string
  }
  fileUniqueId: string
  path: string
  prefix?: string
}

export async function uploadFileObject(
  file: File,
  fileType: FileTypes,
  metadata: FileMetadata,
  context: { userId: number },
  identity?: FileObjectIdentity,
): Promise<UploadedFileObject> {
  let normalizedMetadata = metadata
  try {
    normalizedMetadata = normalizeMetadata(metadata)
    if (file.size === 0) throw badRequest("Uploaded file is empty")

    log.info("Starting file upload", {
      fileType,
      fileSize: file.size,
      extension: normalizedMetadata.extension,
      mimeType: normalizedMetadata.mimeType,
      width: normalizedMetadata.width,
      height: normalizedMetadata.height,
      userId: context.userId,
    })

    const fileUniqueId = identity?.fileUniqueId ?? generateFileUniqueId(fileType)
    const suffix = normalizedMetadata.extension ? `.${normalizedMetadata.extension}` : ""
    const prefix = identity ? undefined : nanoid(32)
    const path = identity?.path ?? `${fileUniqueId}/${prefix}${suffix}`
    try {
      await uploadToBucket(file, {
        path: `${FILES_PATH_PREFIX}/${path}`,
        type: normalizedMetadata.mimeType,
      })
      log.info("File uploaded to bucket successfully", { fileType, userId: context.userId })
    } catch (error) {
      const storageError = describeStorageError(error)
      log.error("Failed to upload file to bucket", {
        error,
        fileType,
        fileSize: file.size,
        mimeType: normalizedMetadata.mimeType,
        extension: normalizedMetadata.extension,
        storageError,
      })
      throw new Error("Failed to upload file to storage", { cause: error as Error })
    }

    let encryptedPath: EncryptedData
    let encryptedName: EncryptedData
    try {
      encryptedPath = encrypt(path)
      encryptedName = encrypt(normalizedMetadata.fileName)
      log.info("File metadata encrypted successfully")
    } catch (error) {
      log.error("Failed to encrypt file metadata", { error })
      throw new Error("Failed to encrypt file metadata", { cause: error as Error })
    }

    return {
      fileUniqueId,
      path,
      prefix,
      dbFile: {
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
        width: normalizedMetadata.width,
        height: normalizedMetadata.height,
        mimeType: normalizedMetadata.mimeType,
      },
    }
  } catch (error) {
    log.error("File upload failed", {
      error,
      fileType,
      fileSize: file.size,
      mimeType: normalizedMetadata.mimeType,
      extension: normalizedMetadata.extension,
      userId: context.userId,
    })
    throw error
  }
}

export async function uploadFile(
  file: File,
  fileType: FileTypes,
  metadata: FileMetadata,
  context: { userId: number },
): Promise<{ dbFile: DbNewFile; fileUniqueId: string; prefix: string }> {
  const prepared = await uploadFileObject(file, fileType, metadata, context)
  if (!prepared.prefix) throw new Error("Generated file upload is missing its object prefix")

  // Save to DB
  try {
    const [dbFile] = await db.insert(files).values(prepared.dbFile).returning()
    if (!dbFile) {
      throw new Error("No file returned from database")
    }
    log.info("File saved to database successfully", { fileUniqueId: prepared.fileUniqueId })
    return { dbFile, fileUniqueId: prepared.fileUniqueId, prefix: prepared.prefix }
  } catch (error) {
    log.error("Failed to save file to database", { error, fileUniqueId: prepared.fileUniqueId })
    throw new Error("Failed to save file to database", { cause: error as Error })
  }
}

function normalizeMetadata(metadata: FileMetadata): FileMetadata {
  const extension = metadata.extension.trim().toLowerCase()
  const mimeType = metadata.mimeType.trim()
  if (!mimeType) {
    throw badRequest("Upload metadata is missing MIME type")
  }

  const fileName = metadata.fileName.trim()
  if (!fileName) {
    throw badRequest("Upload metadata is missing file name")
  }

  return {
    ...metadata,
    extension,
    mimeType,
    fileName,
  }
}

function badRequest(description: string): InlineError {
  const error = new InlineError(ApiError.BAD_REQUEST)
  error.description = description
  return error
}

function describeStorageError(error: unknown): Record<string, unknown> {
  if (!(error instanceof Error)) {
    return { message: String(error) }
  }

  return {
    name: error.name,
    message: error.message,
    cause: error.cause,
  }
}
